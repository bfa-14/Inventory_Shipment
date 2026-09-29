#!/usr/bin/env bash
# Compares the live database with DatabaseProject. READ-ONLY: it changes nothing in the repository or the database.
#   tools/compare-dbproject.sh          summary: objects only in the database / only in the project / different
#   tools/compare-dbproject.sh --diff   the same, plus the changed lines of every different object
# Exit code: 0 = identical, 1 = differences found, 2 = could not run.
#
# How: the database is extracted with sqlpackage exactly like tools/refresh-dbproject.sh does (same layout, schema /
# user definitions in "DatabaseSecurity"), into a temporary folder, and compared file by file with DatabaseProject.
# Line endings and trailing spaces are ignored (git stores LF, Windows checks out CRLF).
# Connection: same as refresh-dbproject.sh - $DB, else $SQLCMDPASSWORD (also read from ~/.bashrc), else appsettings.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PROJ=DatabaseProject
SHOWDIFF=0
[ "${1:-}" = "--diff" ] && SHOWDIFF=1
[ -d "$PROJ" ] || { echo "Not found: $PROJ (run this inside the Inventory_Shipment repository)"; exit 2; }
command -v sqlpackage >/dev/null || { echo "sqlpackage not found: dotnet tool install -g microsoft.sqlpackage"; exit 2; }

if [ -z "${DB:-}" ]; then
  if [ -z "${SQLCMDPASSWORD:-}" ] && [ -f "$HOME/.bashrc" ]; then
    eval "$(grep -m1 '^export SQLCMDPASSWORD=' "$HOME/.bashrc" 2>/dev/null || true)"
  fi
  if [ -n "${SQLCMDPASSWORD:-}" ]; then
    pw="${SQLCMDPASSWORD//\'/\'\'}"
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
        text = re.sub(r",(\s*[}\]])", r"\1", text)
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
  echo "No usable connection. Put the sa password in ~/.bashrc once (first line):  export SQLCMDPASSWORD='<password>'"
  exit 2
fi
case "$DB" in *TrustServerCertificate*) ;; *) DB="$DB;TrustServerCertificate=True" ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Extracting the database schema (read-only)..."
if ! sqlpackage /Action:Extract /SourceConnectionString:"$DB" /TargetFile:"$tmp/db" \
       /p:ExtractTarget=SchemaObjectType /p:IgnorePermissions=True /p:IgnoreUserLoginMappings=True > "$tmp/extract.log" 2>&1; then
  echo "Could not extract the database:"
  { grep -iE 'error|fail|login|connect' "$tmp/extract.log" || tail -5 "$tmp/extract.log"; } | grep -vi 'password' | head -10 || true
  exit 2
fi
[ -d "$tmp/db/Security" ] && mv "$tmp/db/Security" "$tmp/db/DatabaseSecurity"

python3 - "$tmp/db" "$PROJ" "$SHOWDIFF" <<'PY'
import difflib, pathlib, re, sys

db_root, proj_root, show = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"

def objects(root):
    out = {}
    for p in root.rglob("*.sql"):
        rel = p.relative_to(root).as_posix()
        if re.search(r"(^|/)Script\.[^/]*$", rel, re.I):      # pre / post deployment scripts are not database objects
            continue
        out[rel] = p
    return out

def norm(p):
    text = p.read_bytes().decode("utf-8-sig", errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    return [line.rstrip() for line in text.strip("\n").split("\n")]

db, proj = objects(db_root), objects(proj_root)
only_db = sorted(set(db) - set(proj))
only_proj = sorted(set(proj) - set(db))
changed = []
for rel in sorted(set(db) & set(proj)):
    a, b = norm(proj[rel]), norm(db[rel])
    if a != b:
        changed.append((rel, a, b))

# the same object with other capitals shows up once in each list: pair them
lower_db = {r.lower(): r for r in only_db}
case_pairs = [(p, lower_db[p.lower()]) for p in only_proj if p.lower() in lower_db]
for p, d in case_pairs:
    only_proj.remove(p)
    only_db.remove(d)

same = len(set(db) & set(proj)) - len(changed)
print()
print(f"Objects in the database: {len(db)}   in the project: {len(proj)}   identical: {same}")

def section(title, rows, hint):
    print()
    print(f"{title}: {len(rows)}" + (f"   ({hint})" if rows else ""))
    for r in rows[:80]:
        print("   " + r)
    if len(rows) > 80:
        print(f"   ... and {len(rows) - 80} more")

section("Only in the DATABASE", only_db, "not in the project yet - tools/refresh-dbproject.sh adds them")
section("Only in the PROJECT", only_proj, "no longer in the database - tools/refresh-dbproject.sh removes them")
rows = []
for rel, a, b in changed:
    plus = sum(1 for l in difflib.ndiff(a, b) if l.startswith("+ "))
    minus = sum(1 for l in difflib.ndiff(a, b) if l.startswith("- "))
    rows.append(f"{rel}   (+{plus} -{minus} lines)")
section("DIFFERENT", rows, "the database has another version - '+' lines are the database's")
if case_pairs:
    section("Same object, other capitals", [f"{p}  <->  {d}" for p, d in case_pairs], "rename in the database or refresh")

if show and changed:
    print()
    print("=" * 100)
    for rel, a, b in changed:
        print(f"--- project/{rel}")
        print(f"+++ database/{rel}")
        diff = list(difflib.unified_diff(a, b, lineterm="", n=2))[2:]
        for line in diff[:200]:
            print(line)
        if len(diff) > 200:
            print(f"... ({len(diff) - 200} more diff lines)")
        print()

total = len(only_db) + len(only_proj) + len(changed) + len(case_pairs)
print()
if total == 0:
    print("RESULT: the database project is IDENTICAL to the database.")
    sys.exit(0)
print(f"RESULT: {total} difference(s). To bring the project level with the database: git pull, "
      f"tools/refresh-dbproject.sh, then commit and push." + ("" if show else "  (add --diff to see the changed lines)"))
sys.exit(1)
PY
