#!/usr/bin/env bash
# Moves the TESTING database into production's SQL Server, once (README.md, "One SQL Server for both environments"):
#
#   sudo ./share-sql-server.sh           in the testing checkout's deploy folder (/opt/inventory-test/Inventory_Shipment/deploy)
#   sudo ./share-sql-server.sh --undo    back to a SQL Server of testing's own, with testing's data as it is then
#
# Testing then runs no SQL Server: its database is Inventory_Shipment_Test in production's, next to production's
# Inventory_Shipment, and one SSMS connection shows both. Testing's API signs in there as a login of its own,
# inventory_test, which owns testing's database and has no user in production's; testing's scripts (backup, restore,
# copy, reset) act on testing's database only.
#
# What it does - testing is stopped for a few minutes, production's SQL Server restarts once (about half a minute):
#   1. stops testing's API and backs up its database (into deploy/backups, like every backup);
#   2. stops testing's SQL Server; production's joins the network inventory-sql (sql-host.local.yml in production's
#      folder) and takes over the SSMS port of testing's (its db-port.local.yml), unless production has one already;
#   3. restores the backup into production's SQL Server as Inventory_Shipment_Test, owned by inventory_test, with the
#      SQL logins of testing's SQL Server that have a user in it (ssms_user keeps its password); a read-only one
#      (db_datareader) may read production's database too, so one connection shows both;
#   4. writes it in testing's deploy/.env (SHARED_SQL, DB_NAME, DB_SERVER, DB_USER, DB_PASSWORD, COMPOSE_FILE) and
#      starts testing on it.
# Testing's old SQL Server volume (inventory-test_sqldata) is kept for --undo; once all is well:
#   sudo docker volume rm inventory-test_sqldata
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ -f .env ] || die "No deploy/.env - run setup.sh testing first."
ensure_env_defaults
[ "$(environment)" = "testing" ] \
    || die "Run it in the TESTING checkout's deploy folder (/opt/inventory-test/Inventory_Shipment/deploy)."

undo=0
case "${1:-}" in
    "") ;;
    --undo) undo=1 ;;
    *) die "Usage: $0 [--undo]" ;;
esac

production=$(production_deploy)
[ -f "$production/.env" ] && [ -x "$production/backup.sh" ] \
    || die "No production checkout at $production (PRODUCTION_DIR in deploy/.env)."
project=$(env_get COMPOSE_PROJECT_NAME inventory-test)

# ASKED FROM A TERMINAL, before any lock, with five minutes to answer: a forgotten question never holds up a deployment.
{ true </dev/tty; } 2>/dev/null || die "Run this from a terminal: it asks for a confirmation."
echo
if [ "$undo" -eq 0 ]; then
    shared_sql && die "Testing's database is already in production's SQL Server (SHARED_SQL=yes in deploy/.env)."
    echo "This moves testing's database into production's SQL Server: testing stops for a few minutes, and"
    echo "production's SQL Server restarts once (the production app pauses for about half a minute)."
else
    shared_sql || die "Testing's database is not in production's SQL Server: nothing to undo."
    echo "This moves testing's database back into a SQL Server of its own: testing stops for a few minutes."
fi
read -t 300 -rp "Type YES to continue: " answer </dev/tty || die "Cancelled (no answer): nothing was changed."
[ "$answer" = "YES" ] || die "Cancelled: nothing was changed."

# Testing's lock, then production's (the order of every script that takes both): no update, restore, copy or reset
# of either runs meanwhile.
take_env_lock
take_production_lock

# ----- If it stops halfway ------------------------------------------------------------------------------------------
#
# TESTING GOES BACK TO HOW IT WAS, WITH NOTHING LOST: its deploy/.env as it was, on the database it ran on, which nothing
# has changed since its API stopped for the backup - for the move its own SQL Server (its volume is untouched), for
# --undo production's. The SSMS port stays with production's SQL Server when that one runs with it (giving it back would
# restart it again). Production's SQL Server is started again without that port if it does not run with it.
env_saved=$(mktemp)
logins=$(mktemp)
chmod 600 "$env_saved" "$logins"
cp .env "$env_saved"
testing_dir=$(pwd)
changing=0
moved_port=""
rollback() {
    warn "The $([ "$undo" -eq 1 ] && echo "move back" || echo move) did not finish: testing goes back to how it was before (nothing was lost)."
    cd "$testing_dir" || return 1
    # Production's SQL Server must run: with testing's SSMS port only if it runs with it.
    if [ -n "$moved_port" ] && ! (cd "$production" && sql_running); then
        warn "Production's SQL Server does not run: starting it again without testing's SSMS port."
        (cd "$production" && compose_file_remove db-port.local.yml && docker compose up -d --no-build db && wait_for_db)
        moved_port=""
    fi
    (cd "$production" && sql_running) \
        || warn "Production's SQL Server does not run: sudo docker compose up -d db in $production (sudo docker compose logs db)."
    install -m 600 "$env_saved" .env
    rm -f "$env_saved"
    [ -z "$moved_port" ] || compose_file_remove db-port.local.yml
    if docker compose up -d --no-build && (wait_for_api); then
        say "Testing runs as before the $([ "$undo" -eq 1 ] && echo "move back" || echo move). Fix what is said above, then run this again."
    else
        warn "Testing did not start again (above): sudo docker compose up -d in $testing_dir."
    fi
}
on_exit() {
    local status=$?
    rm -f "$logins"
    if [ "$status" -ne 0 ] && [ "$changing" -eq 1 ]; then
        changing=0
        rollback || true
    fi
    rm -f "$env_saved"
}
trap on_exit EXIT
trap 'exit 1' INT TERM HUP

# counts - a few figures of this environment's database, compared before and after the move.
counts() {
    sql_exec -d "$(db_name)" -h -1 -W -s '|' -Q "SET NOCOUNT ON;
        SELECT (SELECT COUNT(*) FROM security.Users), (SELECT COUNT(*) FROM inventory.Items),
               (SELECT COUNT(*) FROM purchase.PurchaseDocuments), (SELECT COUNT(*) FROM inventory.StockMovements),
               (SELECT COUNT(*) FROM logistics.Containers)" | tr -d '[:space:]'
}

# latest_backup - the newest backup of this environment's database in deploy/backups.
latest_backup() {
    find backups -maxdepth 1 -name "$(db_name)-*.bak.gz" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-
}

# ===== --undo ======================================================================================================

if [ "$undo" -eq 1 ]; then
    login=$(env_get DB_USER "$SHARED_TEST_LOGIN")
    before=$(counts)

    say "Stopping testing's API, backing up its database"
    changing=1
    docker compose stop api
    ./backup.sh
    file=$(latest_backup)
    [ -n "$file" ] || die "The backup was not found in deploy/backups."

    say "Testing gets a SQL Server of its own again"
    for name in SHARED_SQL DB_NAME DB_SERVER DB_USER DB_PASSWORD; do env_unset "$name"; done
    compose_file_remove "$SHARED_SQL_FILE"
    docker compose up -d --no-build db
    wait_for_db

    # restore.sh is under this script's locks (INVENTORY_LOCK_HELD), and starts testing's API on the restored database.
    ./restore.sh --yes "$file"
    docker compose up -d --no-build
    wait_for_api
    wait_for_web

    after=$(counts)
    changing=0
    (cd "$production" && sql_exec -Q "IF SUSER_ID(N'$login') IS NOT NULL ALTER LOGIN [$login] DISABLE;") \
        || warn "Could not disable the login $login in production's SQL Server: disable it by hand."

    echo
    say "Testing runs on a SQL Server of its own again: https://$(env_get DOMAIN)"
    echo "    Users, items, documents, stock movements, containers: before $before, after $after"
    echo "    Production's SQL Server still holds a copy of testing's database ($SHARED_TEST_DB, its login $login disabled)."
    echo "    To delete it, in $production:"
    echo "        sudo docker compose exec -T db bash -c 'SQLCMDPASSWORD=\"\$MSSQL_SA_PASSWORD\" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -Q \"DROP DATABASE [$SHARED_TEST_DB]; DROP LOGIN [$login];\"'"
    echo "    Production's SQL Server stays on the network $SQL_NETWORK ($SQL_HOST_FILE in its COMPOSE_FILE), and keeps"
    echo "    an SSMS port it took over from testing (its db-port.local.yml): move that file back to give testing its port."
    exit 0
fi

# ===== The move ====================================================================================================

require_compose 2.24
[ -f "$SHARED_SQL_FILE" ] || die "$(pwd)/$SHARED_SQL_FILE is missing: update testing first (sudo ./update.sh)."
[ -n "$(docker compose ps -q --status running db)" ] || die "Testing's SQL Server is not running (sudo docker compose up -d)."
[ -n "$(cd "$production" && docker compose ps -q --status running db)" ] || die "Production's SQL Server is not running."
production_db=$(cd "$production" && db_name)
[ "${production_db,,}" != "${SHARED_TEST_DB,,}" ] || die "Production's database is called $SHARED_TEST_DB: choose another name for testing's."

# The image that starts on production's SQL Server must be this checkout's: its start-up keeps the schema in its own
# database. (An older one would only be refused there: its login can reach nothing else.)
say "Building testing's API from this checkout"
docker compose build api

before=$(counts)
say "Stopping testing's API, backing up its database"
changing=1
docker compose stop api
./backup.sh
file=$(latest_backup)
[ -n "$file" ] || die "The backup was not found in deploy/backups."

# The SQL logins of testing's SQL Server that have a user in its database (ssms_user for SSMS, ...), with their SID and
# password hash, so they work the same in production's. Kept in a file of root only ($logins), deleted at the end.
sql_exec -d "$(db_name)" -h -1 -W -s '|' -Q "SET NOCOUNT ON;
    SELECT dp.name, sl.name, CONVERT(VARCHAR(200), sl.sid, 1),
           CONVERT(VARCHAR(600), CAST(LOGINPROPERTY(sl.name, 'PasswordHash') AS VARBINARY(256)), 1),
           CAST(sl.is_disabled AS INT),
           CASE WHEN EXISTS (SELECT 1 FROM sys.database_role_members m JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
                             WHERE m.member_principal_id = dp.principal_id AND r.name = N'db_datareader')
                 AND NOT EXISTS (SELECT 1 FROM sys.database_role_members m JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
                                 WHERE m.member_principal_id = dp.principal_id AND r.name <> N'db_datareader')
                THEN 1 ELSE 0 END
    FROM sys.database_principals dp
    JOIN sys.sql_logins sl ON sl.sid = dp.sid
    WHERE dp.type = 'S' AND dp.name NOT IN (N'dbo', N'guest', N'INFORMATION_SCHEMA', N'sys')
      AND sl.name <> N'sa' AND sl.name NOT LIKE N'##%' AND sl.name <> N'$SHARED_TEST_LOGIN';" > "$logins"

# Testing's SSMS port (db-port.local.yml in its COMPOSE_FILE), for production's SQL Server.
test_port_file=""
case ":$(env_get COMPOSE_FILE):" in
    *":db-port.local.yml:"*) [ ! -f db-port.local.yml ] || test_port_file="$testing_dir/db-port.local.yml" ;;
esac

say "Stopping testing's SQL Server (its volume is kept)"
docker compose stop db

# Production's SQL Server: on the shared network, and with testing's SSMS port unless production has its own - one
# restart for both (host_testing_sql).
cd "$production"
port_note=""
if [ -n "$test_port_file" ]; then
    case ":$(env_get COMPOSE_FILE):" in
        *":db-port.local.yml:"*)
            port_note="Production's SQL Server keeps its own SSMS port (its db-port.local.yml); testing's closed with its SQL Server." ;;
        *)
            cp "$test_port_file" db-port.local.yml
            chmod 644 db-port.local.yml
            grep -qxF "deploy/db-port.local.yml" ../.git/info/exclude 2>/dev/null || echo "deploy/db-port.local.yml" >> ../.git/info/exclude
            compose_file_add db-port.local.yml
            moved_port=1
            port_note="The SSMS port of testing's SQL Server now leads to production's, which holds both databases: $(grep -oE '"[0-9.:]*:1433"' db-port.local.yml | tr -d '"' | xargs)." ;;
    esac
fi
host_testing_sql
cd "$testing_dir"

say "Writing testing's deploy/.env: its database in production's SQL Server"
env_set SHARED_SQL yes
env_set DB_NAME "$SHARED_TEST_DB"
env_set DB_SERVER "$SQL_HOST_ALIAS"
env_set DB_USER "$SHARED_TEST_LOGIN"
env_set DB_PASSWORD "$(head -c 2000 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)Aa1"
compose_file_add "$SHARED_SQL_FILE"
[ -z "$moved_port" ] || compose_file_remove db-port.local.yml

# restore.sh restores it, makes inventory_test its owner (ensure_shared_database) and starts testing's API on it,
# under this script's locks (INVENTORY_LOCK_HELD).
./restore.sh --yes "$file"

# The logins, in production's SQL Server: created with the same SID and password unless one of that name is there
# already (then the user is tied to it); a read-only one may read production's database too.
if [ -s "$logins" ]; then
    say "Bringing over the SQL logins of testing's database: $(cut -d'|' -f2 "$logins" | xargs)"
    {
        while IFS='|' read -r user login sid hash disabled readonly; do
            [ -n "$login" ] || continue
            cat <<SQL
BEGIN TRY
    IF SUSER_ID(N'$login') IS NULL
    BEGIN
        CREATE LOGIN [$login] WITH PASSWORD = $hash HASHED, SID = $sid, DEFAULT_DATABASE = [master], CHECK_POLICY = OFF;
        IF $disabled = 1 ALTER LOGIN [$login] DISABLE;
    END
    ELSE IF SUSER_SID(N'$login') <> $sid
    BEGIN
        EXEC (N'USE [$SHARED_TEST_DB]; ALTER USER [$user] WITH LOGIN = [$login];');
        PRINT N'Login $login: production''s SQL Server has one already; testing''s database uses it (with its password).';
    END
    IF $readonly = 1
        EXEC (N'USE [$production_db];
                DECLARE @u SYSNAME = (SELECT name FROM sys.database_principals WHERE sid = SUSER_SID(N''$login''));
                IF @u IS NULL BEGIN CREATE USER [$login] FOR LOGIN [$login]; SET @u = N''$login''; END
                DECLARE @add NVARCHAR(300) = N''ALTER ROLE db_datareader ADD MEMBER '' + QUOTENAME(@u);
                EXEC (@add);');
END TRY
BEGIN CATCH
    PRINT N'Login $login was not brought over: ' + ERROR_MESSAGE();
END CATCH
GO
SQL
        done < "$logins"
    } | sql_stdin -m 1 \
        || warn "Some SQL logins were not brought over (above): create them in production's SQL Server (README.md, \"SQL Server from SSMS on your PC\")."
fi

say "Starting testing without a SQL Server of its own"
docker compose up -d --no-build
wait_for_api
wait_for_web

after=$(counts)
changing=0
[ "$after" = "$before" ] \
    || warn "Users, items, documents, stock movements, containers differ: before $before, after $after. Testing's old volume is kept: sudo ./share-sql-server.sh --undo goes back."

echo
say "Testing's database is in production's SQL Server: https://$(env_get DOMAIN)"
echo "    Databases there: $production_db (production) and $SHARED_TEST_DB (testing), login $SHARED_TEST_LOGIN for testing's API."
echo "    Users, items, documents, stock movements, containers: before $before, after $after"
[ -z "$port_note" ] || echo "    $port_note"
echo "    Testing's old SQL Server volume is kept for --undo. Once all is well: sudo docker volume rm ${project}_sqldata"
