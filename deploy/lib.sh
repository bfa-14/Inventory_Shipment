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

web_dir()  { env_get WEB_SOURCE_DIR ../../Inventory_Shipment_Frontend; }

# production or testing: which of the two environments this checkout runs (README: "Two environments").
environment() { env_get ENVIRONMENT production; }

# ----- One SQL Server for both environments (README.md) ---------------------------------------------------------
#
# Testing's database lives in its own SQL Server (its db container), or in production's: SHARED_SQL=yes in testing's
# deploy/.env, with docker-compose.shared-sql.yml in its COMPOSE_FILE (share-sql-server.sh, setup.sh testing).
# Production's db container then also answers on the network inventory-sql as inventory-db (production's
# sql-host.local.yml), and testing's API signs in there as a login of its own (DB_USER) that owns testing's database
# (DB_NAME) and nothing else: what testing's own SQL Server guaranteed before.

SQL_NETWORK=inventory-sql
SQL_HOST_ALIAS=inventory-db
SHARED_SQL_FILE=docker-compose.shared-sql.yml
SQL_HOST_FILE=sql-host.local.yml
SHARED_TEST_DB=Inventory_Shipment_Test
SHARED_TEST_LOGIN=inventory_test

shared_sql() { [ "$(env_get SHARED_SQL no)" = "yes" ]; }

# production_deploy - production's deploy folder, as testing's deploy/.env knows it.
production_deploy() { printf '%s/deploy' "$(env_get PRODUCTION_DIR /opt/inventory/Inventory_Shipment)"; }

# sql_home - the deploy folder whose db container holds this environment's database.
sql_home() { if shared_sql; then production_deploy; else pwd; fi; }

# db_name - this environment's database.
#
# IN PRODUCTION'S SQL SERVER, TESTING'S DATABASE HAS A NAME OF ITS OWN, written in testing's .env: a DB_NAME line lost
# there must never turn a restore, copy or reset of testing into one of production's database. (Called as
# db=$(db_name): the die ends the subshell, and the failed assignment stops the script under set -e.)
db_name() {
    local db production_db
    db=$(env_get DB_NAME Inventory_Shipment)
    if shared_sql; then
        [ -n "$(env_get DB_NAME)" ] \
            || die "$(pwd)/.env says SHARED_SQL=yes but has no DB_NAME: testing's database in production's SQL Server needs its own name (DB_NAME=$SHARED_TEST_DB)."
        production_db=$(cd "$(production_deploy)" 2>/dev/null && env_get DB_NAME Inventory_Shipment) || production_db=Inventory_Shipment
        [ "${db,,}" != "${production_db,,}" ] \
            || die "Testing's DB_NAME in $(pwd)/.env is production's database ($db): testing must have its own (DB_NAME=$SHARED_TEST_DB)."
    fi
    printf '%s' "$db"
}

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

# env_unset NAME - removes the setting from deploy/.env (its default applies again).
env_unset() {
    local tmp
    [ -f .env ] || return 0
    tmp=$(mktemp)
    grep -v -E "^$1=" .env > "$tmp" || true
    install -m 600 "$tmp" .env
    rm -f "$tmp"
}

# compose_file_add FILE / compose_file_remove FILE - one file in or out of COMPOSE_FILE in deploy/.env, keeping the
# others where they are (docker-compose.yml first, a db-port.local.yml for SSMS...).
compose_file_add() {
    local list
    list=$(env_get COMPOSE_FILE docker-compose.yml)
    case ":$list:" in *":$1:"*) return 0 ;; esac
    env_set COMPOSE_FILE "$list:$1"
}
compose_file_remove() {
    local list kept="" f
    local -a files
    list=$(env_get COMPOSE_FILE docker-compose.yml)
    IFS=: read -ra files <<< "$list"
    for f in "${files[@]}"; do
        [ "$f" = "$1" ] || kept+="${kept:+:}$f"
    done
    if [ -z "$kept" ] || [ "$kept" = "docker-compose.yml" ]; then env_unset COMPOSE_FILE; else env_set COMPOSE_FILE "$kept"; fi
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
    if [ "${INVENTORY_LOCK_HELD:-}" != "$env" ]; then
        exec 9>"/run/lock/inventory-update-$env.lock"
        if ! flock -n 9; then
            say "Another update, restore, copy or reset of $env is running: waiting for it to finish..."
            flock -w 1800 9 || die "The other update, restore, copy or reset of $env has not finished after 30 minutes."
        fi
        export INVENTORY_LOCK_HELD=$env
    fi
    # TESTING ON PRODUCTION'S SQL SERVER WAITS FOR PRODUCTION too: an update of production may restart that SQL Server
    # in the middle of testing's backup or restore.
    if [ "$env" = "testing" ] && shared_sql; then
        take_production_lock
    fi
}

# take_production_lock - production's lock, held to the end of the script, after testing's (always testing first, then
# production: the one order every script follows). Taken once: a second open of the same lock file would wait for
# itself.
take_production_lock() {
    if [ "${INVENTORY_PRODUCTION_LOCK_HELD:-}" = "1" ] || [ "${INVENTORY_LOCK_HELD:-}" = "production" ]; then
        return 0
    fi
    exec 8>"/run/lock/inventory-update-production.lock"
    if ! flock -n 8; then
        say "Production is being updated, restored, copied or reset: waiting for it to finish..."
        flock -w 1800 8 || die "Production is still busy after 30 minutes. Nothing was changed."
    fi
    export INVENTORY_PRODUCTION_LOCK_HELD=1
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

# sql_exec ARGS... - sqlcmd as sa inside the db container of this environment's SQL Server (production's for testing on
# it). The password stays inside the container (SQLCMDPASSWORD from its own environment), so it is never on a command
# line. -I (QUOTED_IDENTIFIER ON), as Schema.sql is applied: writes to tables with filtered indexes or computed columns
# need it. Its input is /dev/null: "exec -T" would otherwise read the terminal and swallow what someone types ahead of
# a question.
sql_exec() {
    ( cd "$(sql_home)" && docker compose exec -T db bash -c \
        'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd -C -I -S localhost -U sa -b "$@"' sqlcmd "$@" </dev/null )
}

# sql_stdin [ARGS...] - the same, the T-SQL read from standard input: for statements that hold a password, which
# must never be on a command line.
sql_stdin() {
    ( cd "$(sql_home)" && docker compose exec -T db bash -c \
        'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd -C -I -S localhost -U sa -b "$@"' sqlcmd "$@" )
}

# sql_running - this environment's SQL Server is up.
sql_running() { [ -n "$(cd "$(sql_home)" && docker compose ps -q --status running db)" ]; }

# The folder where this environment's SQL Server reads and writes backup files: on this server (sql_stage) and as its
# db container sees it (sql_stage_inside). Testing on production's SQL Server has its own subfolder of production's
# deploy/backups (the one that container sees); its backups then move to testing's own deploy/backups.
sql_stage() {
    if shared_sql; then printf '%s/backups/%s' "$(production_deploy)" "$(environment)"; else printf '%s/backups' "$(pwd)"; fi
}
sql_stage_inside() {
    if shared_sql; then printf '/var/opt/mssql/backups/%s' "$(environment)"; else printf '/var/opt/mssql/backups'; fi
}

ensure_backup_dir() {
    local dir
    for dir in backups "$(sql_stage)"; do
        mkdir -p "$dir"
        chown "$MSSQL_UID:0" "$dir"
        chmod 770 "$dir"
    done
}

# ensure_sql_network - the Docker network on which production's SQL Server answers testing's API.
ensure_sql_network() {
    docker network inspect "$SQL_NETWORK" >/dev/null 2>&1 || docker network create "$SQL_NETWORK" >/dev/null
}

# write_sql_host DEPLOY_DIR - production's SQL Server also answers testing's API: on the network inventory-sql, as
# inventory-db. A file of this server only (git ignores it), in production's COMPOSE_FILE. Takes effect at the next
# "docker compose up" of production, which restarts its SQL Server.
write_sql_host() {
    (
        cd "$1"
        cat > "$SQL_HOST_FILE" <<YML
# Written by share-sql-server.sh / setup.sh testing: production's SQL Server also holds testing's database
# (README.md, "One SQL Server for both environments"). Testing's API reaches it on the network $SQL_NETWORK as
# $SQL_HOST_ALIAS. Delete it only together with testing's SHARED_SQL (share-sql-server.sh --undo).
services:
  db:
    networks:
      default:
      sql:
        aliases: [$SQL_HOST_ALIAS]

networks:
  sql:
    name: $SQL_NETWORK
    external: true
YML
        chmod 644 "$SQL_HOST_FILE"
        # A checkout of a branch from before *.local.yml was ignored (deploy/.gitignore) must not see it either.
        grep -qxF "deploy/$SQL_HOST_FILE" ../.git/info/exclude 2>/dev/null \
            || echo "deploy/$SQL_HOST_FILE" >> ../.git/info/exclude
        compose_file_add "$SQL_HOST_FILE"
    )
}

# testing_shares_sql - (in production) testing's database lives in this SQL Server: its deploy/.env says so.
testing_shares_sql() {
    local test_env
    test_env="$(env_get TEST_DIR /opt/inventory-test)/Inventory_Shipment/deploy/.env"
    [ -f "$test_env" ] && grep -qE '^SHARED_SQL=yes[[:space:]]*$' "$test_env"
}

# require_compose VERSION - docker compose at least that version (docker-compose.shared-sql.yml needs 2.24).
require_compose() {
    local have
    have=$(docker compose version --short 2>/dev/null || true)
    have=${have#v}
    [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$1" "$have" | sort -V | head -n 1)" = "$1" ] \
        || die "Docker Compose ${have:-(unknown)} is older than $1, which testing on production's SQL Server needs: sudo apt-get install --only-upgrade docker-compose-plugin"
}

# sql_host_ready [DEPLOY_DIR] - production's db container runs on the network inventory-sql now (not only in its
# files). DEPLOY_DIR: production's deploy folder (from testing's .env when left out).
sql_host_ready() {
    local id
    id=$(cd "${1:-$(production_deploy)}" && docker compose ps -q --status running db)
    [ -n "$id" ] && docker inspect -f '{{json .NetworkSettings.Networks}}' "$id" | grep -q "\"$SQL_NETWORK\""
}

# host_testing_sql - (in production's deploy folder) production's SQL Server also answers testing: sql-host.local.yml,
# the network, and, when its db container is not on that network yet, a restart of it (the app pauses ~30 seconds).
host_testing_sql() {
    local before after
    write_sql_host "$(pwd)"
    ensure_sql_network
    # "up" recreates the db container only when its settings changed (the network, an SSMS port): SQL Server restarts
    # then, and the app pauses for about half a minute.
    before=$(docker compose ps -q db)
    docker compose up -d --no-build db
    after=$(docker compose ps -q db)
    [ "$before" = "$after" ] || say "Production's SQL Server restarted with its new settings"
    wait_for_db
    sql_host_ready "$(pwd)" || die "Production's SQL Server is not on the network $SQL_NETWORK after its restart (docker compose ps in $(pwd))."
}

# wait_for_db - the db container of this folder is healthy (after a restart).
wait_for_db() {
    local id health
    for _ in $(seq 1 60); do
        id=$(docker compose ps -q db)
        health=""
        [ -z "$id" ] || health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")
        [ "$health" = "healthy" ] && return 0
        sleep 5
    done
    docker compose logs --tail 50 db >&2
    die "SQL Server ($(pwd)) was not healthy after 5 minutes. Its log is above."
}

# ensure_shared_database - testing's database in production's SQL Server, OWNED BY TESTING'S LOGIN: inside it that
# login is dbo, as sa was in testing's own SQL Server, and it has no user in any other database. The login gets the
# password of deploy/.env (created, or set again), sent through standard input. Run after every create or restore of
# testing's database: a restore leaves the backup's dbo inside it (own_database_by_sa).
ensure_shared_database() {
    local db login password
    db=$(db_name)
    login=$(env_get DB_USER)
    password=$(env_get DB_PASSWORD)
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || die "Unexpected DB_NAME in $(pwd)/.env: $db"
    [[ "$login" =~ ^[A-Za-z0-9_]+$ ]] && [ "${login,,}" != "sa" ] \
        || die "DB_USER in $(pwd)/.env must be testing's own login (letters, digits, _), not '$login'."
    [ "${#password}" -ge 16 ] && [[ "$password" =~ ^[A-Za-z0-9]+$ ]] \
        || die "DB_PASSWORD in $(pwd)/.env must be 16 letters and digits or more."
    # -m 1: errors only (not "Changed database context").
    sql_stdin -m 1 <<SQL
SET NOCOUNT ON;
IF SUSER_ID(N'$login') IS NULL
    CREATE LOGIN [$login] WITH PASSWORD = N'$password', DEFAULT_DATABASE = [master], CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN [$login] WITH PASSWORD = N'$password', DEFAULT_DATABASE = [master], CHECK_POLICY = OFF;
ALTER LOGIN [$login] ENABLE;
IF DB_ID(N'$db') IS NULL
    CREATE DATABASE [$db];
GO
USE [$db];
-- A user of the login in the database (a restore from elsewhere) would refuse it as the owner.
DECLARE @drop NVARCHAR(300) = (SELECT N'DROP USER ' + QUOTENAME(name) FROM sys.database_principals
                                 WHERE sid = SUSER_SID(N'$login') AND name <> N'dbo');
IF @drop IS NOT NULL
    EXEC (@drop);
GO
ALTER AUTHORIZATION ON DATABASE::[$db] TO [$login];
GO
SQL
}

# own_database_by_sa DB - a database of an environment's own SQL Server after a restore: owned by sa again, inside too,
# and no user of testing's login in it.
#
# A RESTORE KEEPS THE BACKUP'S dbo: restored over a database of sa, a backup of testing's database (on production's SQL
# Server, owned by inventory_test) would leave sa its owner in sys.databases while inventory_test is dbo inside, and
# testing's API could then read and change production's data. ALTER AUTHORIZATION sets both, even to the same owner.
own_database_by_sa() {
    local db=$1
    sql_exec -d "$db" -Q "SET NOCOUNT ON;
        ALTER AUTHORIZATION ON DATABASE::[$db] TO [sa];
        DECLARE @drop NVARCHAR(300) = (SELECT N'DROP USER ' + QUOTENAME(name) FROM sys.database_principals
                                       WHERE sid = SUSER_SID(N'$SHARED_TEST_LOGIN') AND name <> N'dbo');
        IF @drop IS NOT NULL EXEC (@drop);"
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
