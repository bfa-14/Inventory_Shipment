#!/usr/bin/env bash
# Backs up the database (and the keys that encrypt the saved SMTP password) into deploy/backups.
#
#   sudo ./backup.sh
#
# setup.sh schedules it every night; update.sh runs it before every update. Keeps BACKUP_KEEP_DAYS
# days (14 unless deploy/.env says otherwise). The files stay on this server: copy them somewhere
# else regularly, or a lost server takes its backups with it (see README.md). Testing on production's SQL Server
# (README.md, "One SQL Server for both environments") is backed up by that SQL Server, into testing's deploy/backups.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root

db=$(db_name)
keep=$(env_get BACKUP_KEEP_DAYS 14)
stamp=$(date -u +%Y%m%d-%H%M%S)
file="$db-$stamp.bak"

sql_running || die "The SQL Server of $(environment) is not running (sudo docker compose up -d in $(sql_home))."
ensure_backup_dir
stage=$(sql_stage)

# An interrupted backup leaves no half-written .bak behind (gzip replaces a finished one by its .gz).
trap 'rm -f "backups/$file" "$stage/$file"' EXIT
trap 'exit 1' INT TERM HUP

say "Backing up $db to backups/$file.gz"
# No WITH COMPRESSION: the Express edition refuses it. gzip does the same job afterwards.
sql_exec -Q "BACKUP DATABASE [$db] TO DISK = N'$(sql_stage_inside)/$file' WITH CHECKSUM, INIT"
[ "$stage" = "$(pwd)/backups" ] || mv "$stage/$file" "backups/$file"
gzip -f "backups/$file"

if [ -n "$(docker compose ps -q --status running api)" ]; then
    docker compose exec -T api tar -C /app/App_Data -czf - keys > "backups/keys-$stamp.tar.gz"
fi

find backups -maxdepth 1 -type f \( -name '*.bak.gz' -o -name 'keys-*.tar.gz' \) -mtime +"$keep" -delete

say "Done: $(du -h "backups/$file.gz" | cut -f1) in $(pwd)/backups/$file.gz"
