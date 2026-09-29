#!/usr/bin/env bash
# Refreshes DatabaseProject from the live database in one go (the Linux "Schema Compare -> Update project"):
#   check the branch is level with the remote -> extract every object (sqlpackage) -> replace the folder ->
#   rewrite the .sqlproj file list -> run the repository checks -> stage for commit.
# Run it from anywhere inside the repository after applying a new Database/NN_*.sql script:
#   tools/refresh-dbproject.sh
#
# Connection, first one found (the password is never printed):
#   1. $DB                    a full connection string
#   2. $SQLCMDPASSWORD        the same variable sqlcmd uses (also read from the "export SQLCMDPASSWORD=" line of
#                             ~/.bashrc); server / user / database from $SQLCMDSERVER / $SQLCMDUSER / $SQLCMDDBNAME,
#                             default localhost / sa / Inventory_Shipment
#   3. ConnectionStrings:DefaultConnection of Inventory_Shipment.API/appsettings.Development.json, then appsettings.json
#      (Windows-authentication strings are skipped: they cannot work from Linux)
#
# Why it never creates conflicts for the others:
#   - it stops when your branch is behind the remote (refreshing an old copy and pushing it is what makes conflicts);
#   - the output only depends on the database, so two refreshes of the same database give the same files;
#   - schema / user definitions go in "DatabaseSecurity" (sqlpackage calls it "Security", the SAME folder as the
#     "security" schema on Windows - the cause of the files that disappeared on the Windows PCs);
#   - the .sqlproj file list is rewritten to match the files exactly, and tools/check-repo.sh refuses names that
#     differ only by capitals, names Windows cannot create and Visual Studio cache files.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PROJ=DatabaseProject
SQLPROJ="$PROJ/DatabaseProject.sqlproj"
[ -f "$SQLPROJ" ] || { echo "Not found: $SQLPROJ (run this inside the Inventory_Shipment repository)"; exit 1; }
[ -f tools/sync-sqlproj.py ] || { echo "Missing tools/sync-sqlproj.py"; exit 1; }
command -v sqlpackage >/dev/null || { echo "sqlpackage not found: dotnet tool install -g microsoft.sqlpackage"; exit 1; }

# 1. Level with the remote first.
if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
  if GIT_TERMINAL_PROMPT=0 timeout 30 git fetch -q 2>/dev/null; then
    behind="$(git rev-list --count 'HEAD..@{u}')"
    if [ "$behind" -gt 0 ]; then
      echo "STOP: your branch is $behind commit(s) behind $upstream."
      echo "      Run 'git pull' first, then run this script again (nothing was changed)."
      exit 1
    fi
  else
    echo "Warning: could not reach the remote to check for new commits - make sure you ran 'git pull' first."
  fi
fi

# 2. Connection string.
if [ -z "${DB:-}" ]; then
  if [ -z "${SQLCMDPASSWORD:-}" ] && [ -f "$HOME/.bashrc" ]; then
    eval "$(grep -m1 '^export SQLCMDPASSWORD=' "$HOME/.bashrc" 2>/dev/null || true)"
  fi
  if [ -n "${SQLCMDPASSWORD:-}" ]; then
    pw="${SQLCMDPASSWORD//\'/\'\'}"          # quoted value: ; and ' inside the password stay safe
    DB="Server=${SQLCMDSERVER:-localhost};Database=${SQLCMDDBNAME:-Inventory_Shipment};User ID=${SQLCMDUSER:-sa};Password='${pw}';TrustServerCertificate=True;Encrypt=False"
    unset pw
  fi
fi
if [ -z "${DB:-}" ]; then
  DB="$(python3 - <<'PY'
import json, re, pathlib
for name in ("appsettings.Development.json", "appsettings.json"):
    p = pathlib.Path("Inventory_Shipment.API") / name
    if not p.exists():
        continue
    try:
        text = re.sub(r"(?m)^\s*//.*$", "", p.read_text(encoding="utf-8-sig"))
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r",(\s*[}\]])", r"\1", text)          # trailing commas are allowed in .NET settings files
        value = (json.loads(text).get("ConnectionStrings") or {}).get("DefaultConnection") or ""
    except Exception:
        continue
    low = value.lower().replace(" ", "")
    if value and "trusted_connection=true" not in low and "integratedsecurity=true" not in low:
        print(value)
        break
PY
)"
fi
if [ -z "$DB" ]; then
  echo "No usable connection. Put the sa password in ~/.bashrc once (first line), then run the script again:"
  echo "  export SQLCMDPASSWORD='<password>'"
  exit 1
fi
case "$DB" in *TrustServerCertificate*) ;; *) DB="$DB;TrustServerCertificate=True" ;; esac

# 3. Extract, replace the folder, rewrite the file list, stage.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Extracting the database schema..."
if ! sqlpackage /Action:Extract /SourceConnectionString:"$DB" /TargetFile:"$tmp/db" \
       /p:ExtractTarget=SchemaObjectType /p:IgnorePermissions=True /p:IgnoreUserLoginMappings=True > "$tmp/extract.log" 2>&1; then
  echo "STOP: sqlpackage could not extract the database (nothing was changed):"
  { grep -iE 'error|fail|login|connect' "$tmp/extract.log" || tail -5 "$tmp/extract.log"; } | grep -vi 'password' | head -10 || true
  exit 1
fi
[ -d "$tmp/db/Security" ] && mv "$tmp/db/Security" "$tmp/db/DatabaseSecurity"

git rm -r -q --cached --ignore-unmatch -- "$PROJ"
find "$PROJ" -mindepth 1 -maxdepth 1 ! -name '*.sqlproj' ! -name '*.scmp' \
  ! -name '*.refactorlog' ! -name 'Script.*' ! -name '.gitignore' -exec rm -rf {} +
cp -r "$tmp/db/." "$PROJ/"
python3 tools/sync-sqlproj.py "$SQLPROJ"
git -c core.safecrlf=false add -A -- "$PROJ"     # line endings are normalised by .gitattributes

# 4. Same checks as the pre-commit hook: capitals, Windows-invalid names, cache files, .sqlproj list.
if ! tools/check-repo.sh; then
  echo "STOP: fix the problems above before committing."
  exit 1
fi

echo
echo "Changes in $PROJ:"
git status --short -- "$PROJ" | head -60
count="$(git status --short -- "$PROJ" | wc -l)"
if [ "$count" -gt 60 ]; then echo "... and $((count - 60)) more"; fi
if [ "$count" -eq 0 ]; then echo "(none - the project already matches the database)"; exit 0; fi
echo
echo "If this looks right, commit and push it right away (before anyone else pushes):"
echo "  git commit -m \"Database project refreshed\" && git push"
