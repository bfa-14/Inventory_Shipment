# Shared by setup.sh, update.sh, backup.sh and restore.sh - not meant to be run on its own.
# Every script cd's into deploy/ first, so "docker compose" finds docker-compose.yml and .env.

# The SQL Server process in the db container runs as this user; the files it reads or writes in
# deploy/backups must be owned by it.
MSSQL_UID=10001

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run this as root: sudo $0 $*"
}

# env_get NAME [DEFAULT] - one value from deploy/.env, without sourcing the file as shell.
env_get() {
    local value=""
    if [ -f .env ]; then
        value=$(grep -E "^$1=" .env | tail -n 1 | cut -d= -f2-)
        value=${value%\"}; value=${value#\"}; value=${value%\'}; value=${value#\'}
    fi
    printf '%s' "${value:-${2:-}}"
}

db_name()  { env_get DB_NAME Inventory_Shipment; }
web_dir()  { env_get WEB_SOURCE_DIR ../../Inventory_Shipment_Frontend; }

# sql_exec ARGS... - sqlcmd as sa inside the db container. The password stays inside the container
# (SQLCMDPASSWORD from its own environment), so it is never on a command line.
sql_exec() {
    docker compose exec -T db bash -c \
        'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b "$@"' sqlcmd "$@"
}

ensure_backup_dir() {
    mkdir -p backups
    chown "$MSSQL_UID:0" backups
    chmod 770 backups
}

# wait_for_api - until the api container reports healthy; shows its log and fails if it crashes
# (restart: unless-stopped would otherwise keep restarting it quietly) or never becomes healthy.
wait_for_api() {
    local id="" seen="" restarts0=0 restarts health
    say "Waiting for the API to start (a few minutes the first time: it creates the database)..."
    for _ in $(seq 1 120); do
        id=$(docker compose ps -q api)
        if [ -n "$id" ]; then
            if [ "$id" != "$seen" ]; then
                seen=$id
                restarts0=$(docker inspect -f '{{.RestartCount}}' "$id")
            fi
            restarts=$(docker inspect -f '{{.RestartCount}}' "$id")
            health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")
            if [ "$health" = "healthy" ]; then
                say "The API is up."
                return 0
            fi
            if [ "$restarts" -gt "$restarts0" ] || [ "$health" = "unhealthy" ]; then
                docker compose logs --tail 80 api >&2
                die "The API stopped during start-up. Its log is above; fix deploy/.env and run this again."
            fi
        fi
        sleep 5
    done
    docker compose logs --tail 80 api >&2
    die "The API was still not healthy after 10 minutes. Its log is above."
}
