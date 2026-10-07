#!/usr/bin/env bash
# Replaces the database with a backup.
#
#   sudo ./restore.sh backups/Inventory_Shipment-20261005-023000.bak.gz
#   sudo ./restore.sh /root/Inventory_Shipment.bak       # e.g. a backup made in SSMS on your PC
#
# Takes a .bak or .bak.gz made by backup.sh or by SQL Server on Windows (same or older version).
# Stops the API, restores over the current database, and starts the API again, which brings the
# restored database up to the current schema. Asks before overwriting unless --yes is given.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root

source_file=""
assume_yes=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) assume_yes=1 ;;
        *) source_file=$arg ;;
    esac
done
[ -n "$source_file" ] || die "Usage: $0 [--yes] <backup.bak | backup.bak.gz>"
[ -f "$source_file" ] || die "No such file: $source_file"

db=$(db_name)
[ -n "$(docker compose ps -q --status running db)" ] || die "The db container is not running (docker compose up -d db)."

if [ "$assume_yes" -ne 1 ]; then
    echo "This REPLACES the database '$db' with $source_file. Everything entered since that backup is lost."
    read -rp "Type YES to continue: " answer </dev/tty
    [ "$answer" = "YES" ] || die "Cancelled."
fi

# Into deploy/backups, which the db container sees as /var/opt/mssql/backups, unpacked and readable
# by SQL Server.
ensure_backup_dir
name="restore-$(date -u +%Y%m%d-%H%M%S).bak"
case "$source_file" in
    *.gz) gunzip -c "$source_file" > "backups/$name" ;;
    *)    cp "$source_file" "backups/$name" ;;
esac
chown "$MSSQL_UID:0" "backups/$name"
chmod 640 "backups/$name"
inside="/var/opt/mssql/backups/$name"

# A backup remembers where its files lived (C:\Program Files\...\DATA on Windows): every file has to
# be moved to the container's data folder, under names of this database.
say "Reading the backup's file list"
filelist=$(sql_exec -h -1 -W -s '|' -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'$inside'")
moves=""
data_index=0
log_index=0
while IFS='|' read -r logical _physical type _rest; do
    case "$type" in
        D) if [ "$data_index" -eq 0 ]; then target="${db}.mdf"; else target="${db}_${data_index}.ndf"; fi
           data_index=$((data_index + 1)) ;;
        L) if [ "$log_index" -eq 0 ]; then target="${db}_log.ldf"; else target="${db}_log_${log_index}.ldf"; fi
           log_index=$((log_index + 1)) ;;
        *) continue ;;
    esac
    moves+=", MOVE N'${logical//\'/\'\'}' TO N'/var/opt/mssql/data/${target}'"
done <<< "$filelist"
[ "$data_index" -gt 0 ] || die "Could not read the file list of $source_file - is it a SQL Server backup?"

say "Stopping the API"
docker compose stop api

say "Restoring $db"
if ! sql_exec -Q "RESTORE DATABASE [$db] FROM DISK = N'$inside' WITH REPLACE, STATS = 25${moves}"; then
    rm -f "backups/$name"
    docker compose start api
    die "The restore failed (see above). The API was started again on the database as it was."
fi
rm -f "backups/$name"

say "Starting the API (it updates the restored database to the current schema)"
docker compose start api
wait_for_api
say "Restored $source_file into $db."
