#!/usr/bin/env bash
# Refreshes DatabaseProject from the live database in one go:
#   extract every object (sqlpackage) -> replace the folder -> rewrite the .sqlproj file list -> stage for commit.
# Run it from anywhere inside the repository after applying a new Database/NN_*.sql script:
#   tools/refresh-dbproject.sh
# Connection: $DB if set, otherwise the first connection string of Inventory_Shipment.API/appsettings.Development.json.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PROJ=DatabaseProject
SQLPROJ="$PROJ/DatabaseProject.sqlproj"
[ -f "$SQLPROJ" ] || { echo "Not found: $SQLPROJ (run this inside the Inventory_Shipment repository)"; exit 1; }
command -v sqlpackage >/dev/null || { echo "sqlpackage not found: dotnet tool install -g microsoft.sqlpackage"; exit 1; }

if [ -z "${DB:-}" ]; then
  DB="$(python3 - <<'PY'
import json, re, pathlib
p = pathlib.Path("Inventory_Shipment.API/appsettings.Development.json")
text = re.sub(r"(?m)^\s*//.*$", "", p.read_text(encoding="utf-8-sig"))
cs = json.loads(text).get("ConnectionStrings", {})
value = cs.get("DefaultConnection") or next(iter(cs.values()), "")
print(value)
PY
)"
fi
[ -n "$DB" ] || { echo "No connection string: export DB=\"Server=...;Database=...;User ID=...;Password=...\""; exit 1; }
case "$DB" in *TrustServerCertificate*) ;; *) DB="$DB;TrustServerCertificate=True" ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Extracting the database schema..."
sqlpackage /Action:Extract /SourceConnectionString:"$DB" /TargetFile:"$tmp/db" \
  /p:ExtractTarget=SchemaObjectType /p:IgnorePermissions=True /p:IgnoreUserLoginMappings=True >/dev/null

git rm -r -q --cached --ignore-unmatch -- "$PROJ"
find "$PROJ" -mindepth 1 -maxdepth 1 ! -name '*.sqlproj' ! -name '*.scmp' \
  ! -name '*.refactorlog' ! -name 'Script.*' ! -name '.gitignore' -exec rm -rf {} +
cp -r "$tmp/db/." "$PROJ/"
python3 tools/sync-sqlproj.py "$SQLPROJ"
git add -A -- "$PROJ"

dups="$(git ls-files "$PROJ" | sort -f | uniq -Di || true)"
if [ -n "$dups" ]; then
  echo "STOP: the same file exists twice with different capitals (breaks Windows checkouts):"
  echo "$dups"
  exit 1
fi

echo
echo "Changes in $PROJ:"
git status --short -- "$PROJ" | head -60
count="$(git status --short -- "$PROJ" | wc -l)"
[ "$count" -gt 60 ] && echo "... and $((count - 60)) more"
[ "$count" -eq 0 ] && echo "(none - the project already matches the database)"
echo
echo "If this looks right:  git commit -m \"Database project refreshed\" && git push"
