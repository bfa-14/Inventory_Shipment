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

# production or testing: which of the two environments this checkout runs (README: "Two environments").
environment() { env_get ENVIRONMENT production; }

# env_set NAME VALUE - writes one value into deploy/.env, replacing the line if there is one.
env_set() {
    local tmp
    tmp=$(mktemp)
    if [ -f .env ]; then
        grep -v -E "^$1=" .env > "$tmp" || true
    fi
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    install -m 600 "$tmp" .env
    rm -f "$tmp"
}

# ensure_env_defaults - gives a .env written before the testing environment existed what the current
# docker-compose.yml needs, so an update of such a server keeps working: it is production, and the
# testing address is test.<its domain> (the proxy serves both).
#
# ONLY AN OLD PRODUCTION .env MAY BE TAKEN FOR PRODUCTION. Testing's .env is written by setup.sh testing
# with ENVIRONMENT=testing; if that line is ever lost (a hand edit), defaulting to production would let
# testing email the real people in its copy of production's data. Testing's .env is recognisable by what
# only it holds, so it stops here instead.
ensure_env_defaults() {
    [ -f .env ] || return 0
    local domain
    if [ -z "$(env_get ENVIRONMENT)" ]; then
        if [ -n "$(env_get PRODUCTION_DIR)" ] || [ "$(env_get PROXY_REPLICAS 1)" = "0" ] \
            || [ "$(env_get COMPOSE_PROJECT_NAME inventory)" != "inventory" ] \
            || grep -qE '^[[:space:]]*(export[[:space:]]+)?ENVIRONMENT[[:space:]]*[=:]' .env; then
            die "deploy/.env has no usable ENVIRONMENT= line, and it is not production's: write ENVIRONMENT=testing (or production) at the start of a line in $(pwd)/.env, then run this again."
        fi
        env_set ENVIRONMENT production
        say "deploy/.env: ENVIRONMENT=production added"
    fi
    case "$(environment)" in
        production | testing) ;;
        *) die "ENVIRONMENT in $(pwd)/.env is '$(environment)': it must be production or testing." ;;
    esac
    if [ "$(environment)" = "production" ] && [ -z "$(env_get TEST_DOMAIN)" ]; then
        domain=$(env_get DOMAIN)
        [ -n "$domain" ] || die "DOMAIN is empty in deploy/.env."
        env_set TEST_DOMAIN "test.$domain"
        say "deploy/.env: TEST_DOMAIN=test.$domain added (the address of the testing environment)"
    fi
}

# take_env_lock - one update, restore or copy of an environment at a time (a push can start a deployment
# while someone restores by hand). Waits for the other one up to 30 minutes. The lock is held until the
# script ends, across exec and by the scripts it runs; INVENTORY_LOCK_HELD tells those not to take it again
# (they would wait for themselves).
take_env_lock() {
    local env
    env=$(environment)
    [ "${INVENTORY_LOCK_HELD:-}" = "$env" ] && return 0
    exec 9>"/run/lock/inventory-update-$env.lock"
    if ! flock -n 9; then
        say "Another update, restore, copy or reset of $env is running: waiting for it to finish..."
        flock -w 1800 9 || die "The other update, restore, copy or reset of $env has not finished after 30 minutes."
    fi
    export INVENTORY_LOCK_HELD=$env
}

# require_proxy_web DIR - the frontend checkout must be the version made for the proxy (its web container
# serves plain HTTP and /environment.json). An older one needs DOMAIN in the web container and would
# restart over and over behind the proxy, every page then answering 502.
require_proxy_web() {
    grep -q environment.json "$1/Caddyfile" 2>/dev/null \
        || die "The frontend in $(realpath "$1") ($(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)) is older than the two-environment deployment (its Caddyfile has no environment.json): merge main into that branch of Inventory_Shipment_Frontend, then run this again. Nothing was rebuilt or restarted."
}

# open_web_ports - lets ports 80 and 443 through ufw for the proxy. The proxy runs on the host network, so ufw
# applies to it (the web container's published ports of the old layout went around ufw). Only touched when ufw
# is already on: turning it on here could lock out an SSH session on another port.
open_web_ports() {
    if command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
        say "Opening ports 80 and 443 in ufw"
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ufw allow 443/udp >/dev/null
    fi
}

# sql_exec ARGS... - sqlcmd as sa inside the db container. The password stays inside the container
# (SQLCMDPASSWORD from its own environment), so it is never on a command line. -I (QUOTED_IDENTIFIER ON), as
# Schema.sql is applied: writes to tables with filtered indexes or computed columns need it. Its input is /dev/null:
# "exec -T" would otherwise read the terminal and swallow what someone types ahead of a question.
sql_exec() {
    docker compose exec -T db bash -c \
        'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd -C -I -S localhost -U sa -b "$@"' sqlcmd "$@" </dev/null
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

# wait_for_web - after wait_for_api: the web app answers on 127.0.0.1:TUNNEL_PORT and, in production, the
# proxy is running. Without it a web or proxy that cannot start (a bad Caddyfile) would still end in "Updated".
wait_for_web() {
    local port id restarts previous=""
    port=$(env_get TUNNEL_PORT 8080)
    say "Checking the web app$([ "$(environment)" = production ] && echo ' and the proxy')..."
    for _ in $(seq 1 24); do
        if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$port/environment.json" 2>/dev/null; then
            [ "$(environment)" = "production" ] || return 0
            # Running, and not restarting between two looks five seconds apart.
            id=$(docker compose ps -q --status running proxy)
            if [ -n "$id" ]; then
                restarts=$(docker inspect -f '{{.RestartCount}}' "$id")
                [ "$restarts" = "$previous" ] && return 0
                previous=$restarts
            fi
        fi
        sleep 5
    done
    docker compose logs --tail 50 web >&2
    [ "$(environment)" = "production" ] && docker compose logs --tail 50 proxy >&2
    die "The web app (127.0.0.1:$port) or the proxy did not come up. The log is above."
}
