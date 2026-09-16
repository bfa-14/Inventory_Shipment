#!/usr/bin/env bash
# Pull the live database schema into this database project (tables, views, procs,
# functions, triggers, indexes, schemas, permissions). Data is not included.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
CONN="${DB_CONN:-Server=localhost;Database=Inventory_Shipment;User Id=sa;Password=p@ssW0rd;TrustServerCertificate=True}"

TMP=$(mktemp -d)
sqlpackage /Action:Extract /p:ExtractTarget=SchemaObjectType \
  /TargetFile:"$TMP/db" "/SourceConnectionString:$CONN"

# replace the object folders; the .sqlproj and any Scripts/ folder are untouched
for d in "$TMP/db"/*/; do
  name=$(basename "$d")
  rm -rf "$PROJ/$name"
  cp -r "$d" "$PROJ/$name"
done
rm -rf "$TMP"

cd "$PROJ" && dotnet build -nologo -v q       # proves the project still compiles
git -C "$PROJ" status --short | head -40
echo "Done - review 'git diff' and commit."