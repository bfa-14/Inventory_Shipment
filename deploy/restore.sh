#!/usr/bin/env bash
# Replaces the database with a backup.
#
#   sudo ./restore.sh backups/Inventory_Shipment-20261005-023000.bak.gz
#   sudo ./restore.sh /root/Inventory_Shipment.bak       # e.g. a backup made in SSMS on your PC
#
# Takes a .bak or .bak.gz made by backup.sh or by SQL Server on Windows (same or older version).
# Stops the API, restores over the current database, and starts the API again, which brings the
# restored database up to the current schema. Asks before overwriting unless --yes is given.
#
# RESTORE_THEN_SQL (for copy-production-to-testing.sh): T-SQL run on the restored database before the API
# starts on it, so the API never sees the backup as it was.
#
# The restored database gets its owner back, inside it too: testing's own login for testing on production's SQL Server
# (README.md, "One SQL Server for both environments"), sa otherwise, with no user of testing's login left in it.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
take_env_lock

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
sql_running || die "The SQL Server of $(environment) is not running (sudo docker compose up -d in $(sql_home))."

if [ "$assume_yes" -ne 1 ]; then
    echo "This REPLACES the database '$db' with $source_file. Everything entered since that backup is lost."
    read -rp "Type YES to continue: " answer </dev/tty
    [ "$answer" = "YES" ] || die "Cancelled."
fi

# Into the folder the SQL Server's container sees as /var/opt/mssql/backups (deploy/backups, or testing's subfolder of
# production's), unpacked and readable by SQL Server.
ensure_backup_dir
stage=$(sql_stage)
name="restore-$(date -u +%Y%m%d-%H%M%S).bak"
case "$source_file" in
    *.gz) gunzip -c "$source_file" > "$stage/$name" ;;
    *)    cp "$source_file" "$stage/$name" ;;
esac
chown "$MSSQL_UID:0" "$stage/$name"
chmod 640 "$stage/$name"
inside="$(sql_stage_inside)/$name"
trap 'rm -f "$stage/$name"' EXIT
trap 'exit 1' INT TERM HUP

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
# SINGLE_USER first, in the same batch: a session still open in it (SSMS) would refuse the restore.
if ! sql_exec -Q "IF DB_ID(N'$db') IS NOT NULL ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                  RESTORE DATABASE [$db] FROM DISK = N'$inside' WITH REPLACE, STATS = 25${moves}"; then
    rm -f "$stage/$name"
    sql_exec -Q "IF DB_ID(N'$db') IS NOT NULL ALTER DATABASE [$db] SET MULTI_USER;" || true
    docker compose start api
    die "The restore failed (see above). The API was started again on the database as it was."
fi
rm -f "$stage/$name"

# The owner, inside the database too: a restore keeps the backup's dbo (lib.sh, own_database_by_sa).
if shared_sql; then
    ensure_shared_database
else
    own_database_by_sa "$db"
fi

if [ -n "${RESTORE_THEN_SQL:-}" ]; then
    say "Adjusting the restored database"
    sql_exec -d "$db" -Q "$RESTORE_THEN_SQL" \
        || die "The database was restored, but adjusting it failed (above). The API is stopped: run this again."
fi

# A RESTORE ABANDONS AN UNFINISHED RESET (reset-database.sh): its side database would otherwise be taken for work
# still to finish, and would keep copy-production-to-testing.sh refusing.
sql_exec -Q "IF DB_ID(N'${db}_reset_keep') IS NOT NULL DROP DATABASE [${db}_reset_keep];"

say "Starting the API (it updates the restored database to the current schema)"
# "up" (not "start"): a changed setting, such as the signing key copy-production-to-testing.sh renews, is taken.
docker compose up -d --no-build api
wait_for_api
say "Restored $source_file into $db."
