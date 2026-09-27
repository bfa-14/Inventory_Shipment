#!/usr/bin/env bash
# Refreshes DatabaseProject from the live database in one go:
#   extract every object (sqlpackage) -> replace the folder -> rewrite the .sqlproj file list -> stage for commit.
# Run it from anywhere inside the repository after applying a new Database/NN_*.sql script:
#   tools/refresh-dbproject.sh
# Connection: $DB if set, otherwise ConnectionStrings:DefaultConnection of Inventory_Shipment.API/appsettings.Development.json,
# then appsettings.json (Windows-authentication strings are skipped: they cannot work from Linux).
#
# Folder layout: <schema>/<ObjectType>/<object>.sql, and the schema / user definitions in "DatabaseSecurity".
# (sqlpackage calls that folder "Security", which is the SAME folder as the "security" schema on Windows - the cause of
#  files disappearing on the Windows PCs. Renaming it removes the clash.)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PROJ=DatabaseProject
SQLPROJ="$PROJ/DatabaseProject.sqlproj"
[ -f "$SQLPROJ" ] || { echo "Not found: $SQLPROJ (run this inside the Inventory_Shipment repository)"; exit 1; }
[ -f tools/sync-sqlproj.py ] || { echo "Missing tools/sync-sqlproj.py"; exit 1; }
command -v sqlpackage >/dev/null || { echo "sqlpackage not found: dotnet tool install -g microsoft.sqlpackage"; exit 1; }

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
  echo "No usable connection string found. Set it once for this terminal, then run the script again:"
  echo "  export DB=\"Server=localhost;Database=Inventory_Shipment;User ID=sa;Password=<password>;TrustServerCertificate=True;Encrypt=False\""
  exit 1
fi
case "$DB" in *TrustServerCertificate*) ;; *) DB="$DB;TrustServerCertificate=True" ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Extracting the database schema..."
sqlpackage /Action:Extract /SourceConnectionString:"$DB" /TargetFile:"$tmp/db" \
  /p:ExtractTarget=SchemaObjectType /p:IgnorePermissions=True /p:IgnoreUserLoginMappings=True >/dev/null
[ -d "$tmp/db/Security" ] && mv "$tmp/db/Security" "$tmp/db/DatabaseSecurity"

git rm -r -q --cached --ignore-unmatch -- "$PROJ"
find "$PROJ" -mindepth 1 -maxdepth 1 ! -name '*.sqlproj' ! -name '*.scmp' \
  ! -name '*.refactorlog' ! -name 'Script.*' ! -name '.gitignore' -exec rm -rf {} +
cp -r "$tmp/db/." "$PROJ/"
python3 tools/sync-sqlproj.py "$SQLPROJ"
git add -A -- "$PROJ"

# Folders or files whose names differ only by capitals end up merged on Windows: refuse to continue.
clash="$(git ls-files "$PROJ" | python3 -c '
import sys, collections
seen = collections.defaultdict(set)
for line in sys.stdin:
    parts = line.rstrip("\n").split("/")
    for i in range(1, len(parts) + 1):
        seen["/".join(parts[:i]).lower()].add("/".join(parts[:i]))
for variants in seen.values():
    if len(variants) > 1:
        print("  " + "  <->  ".join(sorted(variants)))
')"
if [ -n "$clash" ]; then
  echo "STOP: names that differ only by capitals (they merge on Windows):"
  echo "$clash"
  exit 1
fi

echo
echo "Changes in $PROJ:"
git status --short -- "$PROJ" | head -60
count="$(git status --short -- "$PROJ" | wc -l)"
if [ "$count" -gt 60 ]; then echo "... and $((count - 60)) more"; fi
if [ "$count" -eq 0 ]; then echo "(none - the project already matches the database)"; fi
echo
echo "If this looks right:  git commit -m \"Database project refreshed\" && git push"
