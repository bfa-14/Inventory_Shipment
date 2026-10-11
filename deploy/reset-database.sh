#!/usr/bin/env bash
# Empties this environment's database: it becomes exactly what a new installation creates, except that
# the administrator is the account you have now (same user name, email and password).
#
#   sudo ./reset-database.sh                     in the deploy folder of the environment to empty
#   sudo KEEP_USER=bilal ./reset-database.sh     keep another administrator account (default: admin)
#
# Everything else goes: documents, stock and costs, containers, items, suppliers and customers, other users and
# roles, settings, emails, attached files. Document numbers start again at 1. Everyone is signed out.
#
# WHAT A NEW INSTALLATION CREATES COMES BACK, and would come back at every start if deleted: the document types,
# the permissions, the default settings, the roles Admin / Manager / User / Owner (only the kept account holds
# one), and the starter rows of an empty database: branch BR-001 Head Office and its warehouse, the currencies,
# ports, item families, unit, container, movement and charge types, attachment types, stock reasons, payment
# methods, the TVS brand, supplier SUP-0001, customer CLI-0001 Walk-in Customer, the demo item TVS-AP160 and price
# list PL-001 with its price. Change, deactivate or delete them in the app.
#
# A backup is taken first and kept in deploy/backups/before-reset (not pruned after 14 days like the nightly ones).
# To empty testing too, copy the emptied production into it afterwards:
#   sudo /opt/inventory-test/Inventory_Shipment/deploy/copy-production-to-testing.sh
#
# How: the kept account is saved inside SQL Server (a small side database, <db>_reset_keep; the password hash never
# leaves SQL Server), the database is dropped, the API creates a new one as on a first installation (Schema.sql,
# and the administrator of ADMIN_PASSWORD), and the kept account then replaces that administrator. Interrupted
# (a lost connection), it carries on from where it stopped when run again.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ -f .env ] || die "No deploy/.env - run setup.sh first."
ensure_env_defaults
take_env_lock

env_name=$(environment)
db=$(db_name)
keep_db="${db}_reset_keep"
domain=$(env_get DOMAIN)
keep=${KEEP_USER:-admin}
[[ "$keep" =~ ^[A-Za-z0-9._@-]+$ ]] || die "Not a user name: $keep"
[[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || die "Unexpected DB_NAME in deploy/.env: $db"
[ -n "$(docker compose ps -q --status running db)" ] || die "The db container is not running (sudo docker compose up -d)."

# ONE VALUE FROM SQL SERVER, without headers or "rows affected".
sql_value() { sql_exec -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d '[:space:]'; }
db_exists() { sql_value "SELECT COUNT(*) FROM sys.databases WHERE name = N'$1'"; }

# ----- Where a previous run stopped --------------------------------------------------------------------------
#
# The side database exists from the moment the account is being saved until the very end. Carry on with the account
# it saved, and the backup it recorded (never a backup of the new, empty database), only when the database is gone
# or is the new one the API built: newer than the side database, not restored since, with at most one user. (A
# RESTORE also makes a database newer, hence msdb's restore history; restore.sh drops the side database anyway.)
# Otherwise nothing was
# deleted yet, or the old data was restored since: forget the side database (its saved account may be stale, e.g.
# its password changed since) and start again. The database gone without a saved account: only the backup helps.
resuming=0
backup_file=""
if [ "$(db_exists "$keep_db")" != "0" ]; then
    saved=$(sql_value "SELECT COUNT(*) FROM [$keep_db].sys.tables WHERE name = N'KeepUser'")
    [ "$saved" = "1" ] && saved=$(sql_value "SELECT COUNT(*) FROM [$keep_db].dbo.KeepUser")
    has_info=$(sql_value "SELECT COUNT(*) FROM [$keep_db].sys.tables WHERE name = N'KeepInfo'")
    [ "$has_info" = "1" ] && backup_file=$(sql_value "SELECT TOP (1) BackupFile FROM [$keep_db].dbo.KeepInfo")
    new_db=1
    if [ "$(db_exists "$db")" != "0" ]; then
        new_db=$(sql_value "IF (SELECT create_date FROM sys.databases WHERE name = N'$db')
                                 < (SELECT create_date FROM sys.databases WHERE name = N'$keep_db')
                                SELECT 0;
                            ELSE IF EXISTS (SELECT 1 FROM msdb.dbo.restorehistory
                                            WHERE destination_database_name = N'$db'
                                              AND restore_date >= (SELECT create_date FROM sys.databases WHERE name = N'$keep_db'))
                                SELECT 0;
                            ELSE IF OBJECT_ID(N'[$db].security.Users', N'U') IS NULL
                                SELECT 1;
                            ELSE
                                SELECT CASE WHEN (SELECT COUNT(*) FROM [$db].security.Users) <= 1 THEN 1 ELSE 0 END;")
    fi
    if [ "$saved" = "1" ] && [ "$new_db" = "1" ]; then
        resuming=1
        keep=$(sql_value "SELECT Username FROM [$keep_db].dbo.KeepUser")
        say "A previous reset of $env_name did not finish: carrying on with the account '$keep' it saved."
    elif [ "$(db_exists "$db")" != "0" ]; then
        sql_exec -Q "DROP DATABASE [$keep_db];"
        backup_file=""
    else
        die "A previous reset deleted the $env_name database without saving the account. Restore the backup it took (${backup_file:-the newest file in $(pwd)/backups/before-reset}: sudo ./restore.sh <that file>), then run this again."
    fi
fi

if [ "$resuming" -eq 0 ]; then
    [ "$(db_exists "$db")" = "1" ] || die "There is no $db database in $env_name to empty."
    # The kept account must be an active administrator now: it is the only way into the emptied database.
    found=$(sql_value "SELECT COUNT(DISTINCT u.Id) FROM [$db].security.Users u
        JOIN [$db].security.UserRoles ur ON ur.UserId = u.Id
        JOIN [$db].security.Roles r ON r.Id = ur.RoleId AND r.IsSystem = 1
        WHERE u.Username = N'$keep' AND u.IsActive = 1")
    if [ "$found" != "1" ]; then
        admins=$(sql_exec -h -1 -W -Q "SET NOCOUNT ON; SELECT DISTINCT u.Username FROM [$db].security.Users u
            JOIN [$db].security.UserRoles ur ON ur.UserId = u.Id JOIN [$db].security.Roles r ON r.Id = ur.RoleId AND r.IsSystem = 1
            WHERE u.IsActive = 1" | xargs)
        die "'$keep' is not an active administrator of $env_name. Administrators: ${admins:-none}. Run: sudo KEEP_USER=<one of them> ./reset-database.sh"
    fi
fi

# ----- The address typed back --------------------------------------------------------------------------------

# A REAL TERMINAL: this deletes everything, and nothing scripted should do it by accident. Five minutes to answer,
# so a forgotten prompt does not hold the environment's lock (deployments wait for it).
{ true </dev/tty; } 2>/dev/null || die "Run this from a terminal: it asks for a confirmation."
echo
if [ "$resuming" -eq 0 ]; then
    echo "This EMPTIES the $env_name database ($db) of https://$domain:"
    echo "everything entered is deleted; only the account '$keep' stays, with its current password."
    echo "A backup is taken first. Everyone is signed out."
else
    echo "This FINISHES emptying the $env_name database ($db) of https://$domain, keeping the account '$keep'."
    [ -z "$backup_file" ] || echo "The backup taken before: $(pwd)/$backup_file"
fi
read -t 300 -rp "Type the address $domain to continue: " answer </dev/tty || die "Cancelled (no answer): nothing was changed."
[ "$answer" = "$domain" ] || die "Cancelled: nothing was changed."

# ----- Backup, save the account, delete ----------------------------------------------------------------------

if [ "$resuming" -eq 0 ]; then
    ./backup.sh
    latest=$(find backups -maxdepth 1 -name "$db-*.bak.gz" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
    [ -n "$latest" ] || die "The backup was not found in deploy/backups: nothing was changed."
    # Out of reach of the nightly clean-up (backup.sh prunes deploy/backups itself only, after BACKUP_KEEP_DAYS):
    # a hard link costs no space and survives the pruning of the original name.
    stamp=${latest##*/"$db"-}; stamp=${stamp%.bak.gz}
    mkdir -p backups/before-reset
    for f in "$latest" "backups/keys-$stamp.tar.gz"; do
        if [ -f "$f" ]; then ln -f "$f" backups/before-reset/ 2>/dev/null || cp -p "$f" backups/before-reset/; fi
    done
    backup_file="backups/before-reset/${latest##*/}"

    say "Saving the account '$keep'"
    sql_exec -Q "SET NOCOUNT ON; CREATE DATABASE [$keep_db];"
    sql_exec -Q "SET NOCOUNT ON;
        CREATE TABLE [$keep_db].dbo.KeepInfo (BackupFile NVARCHAR(400) NOT NULL);
        INSERT INTO [$keep_db].dbo.KeepInfo (BackupFile) VALUES (N'$backup_file');
        SELECT Username, Email, FullName, PasswordHash INTO [$keep_db].dbo.KeepUser
        FROM [$db].security.Users WHERE Username = N'$keep';"
    [ "$(sql_value "SELECT COUNT(*) FROM [$keep_db].dbo.KeepUser")" = "1" ] || die "Saving the account failed: nothing else was changed."

    say "Deleting the $env_name database"
    docker compose stop api
    # A NEW SIGNING KEY signs everyone out: a sign-in made before carries a user id that now means someone else, or
    # nobody. Written now, while the API is stopped, so its next start (below) takes it.
    env_set JWT_SECRET_KEY "$(head -c 2000 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 64)"
    sql_exec -Q "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db];"
fi

# ----- The new database --------------------------------------------------------------------------------------

# "up" recreates the API only when its settings changed (the new key of a fresh run) and starts it when it is stopped.
# A resumed run changes nothing, so an API still building the new database is never stopped in the middle of it.
say "Creating the new database (the API builds it as on a first installation)"
docker compose up -d --no-build api
wait_for_api

# The new database's administrator (from ADMIN_PASSWORD) takes the kept account's identity and password; without one
# (ADMIN_PASSWORD empty or refused), the kept account is created. Either way it holds the Admin role. Run again after
# an interruption, it finds the account already in place and changes nothing.
say "Restoring the account '$keep'"
sql_exec -d "$db" -Q "SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DECLARE @AdminRoleId INT = (SELECT Id FROM security.Roles WHERE Name = N'Admin' AND IsSystem = 1);
    IF @AdminRoleId IS NULL THROW 50000, 'The new database has no Admin role.', 1;
    IF (SELECT COUNT(*) FROM security.Users) > 1 THROW 50000, 'The new database has more than one user: it is not the new one.', 1;
    DECLARE @UserId INT = (SELECT TOP (1) Id FROM security.Users ORDER BY Id);
    IF @UserId IS NULL
    BEGIN
        INSERT INTO security.Users (Username, Email, FullName, PasswordHash, IsActive)
        SELECT Username, Email, FullName, PasswordHash, 1 FROM [$keep_db].dbo.KeepUser;
        SET @UserId = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE u SET Username = k.Username, Email = k.Email, FullName = k.FullName, PasswordHash = k.PasswordHash,
                     IsActive = 1, FailedLoginAttempts = 0, LockoutEndUtc = NULL, UpdatedAtUtc = SYSUTCDATETIME()
        FROM security.Users u CROSS JOIN [$keep_db].dbo.KeepUser k WHERE u.Id = @UserId;
    IF NOT EXISTS (SELECT 1 FROM security.UserRoles WHERE UserId = @UserId AND RoleId = @AdminRoleId)
        INSERT INTO security.UserRoles (UserId, RoleId) VALUES (@UserId, @AdminRoleId);
    COMMIT;" \
    || die "The account '$keep' was not restored (the error is above). It is still saved: run this again."
[ "$(sql_value "SELECT COUNT(*) FROM [$db].security.Users WHERE Username = N'$keep'")" = "1" ] \
    || die "The account '$keep' was not restored. It is still saved: run this again."

sql_exec -Q "DROP DATABASE [$keep_db];"

echo
say "The $env_name database is empty: https://$domain"
echo "    Sign in as '$keep' with your current password (everyone was signed out)."
echo "    Set up again: Configuration > Settings (Email, Purchase approval, General), then your master data."
if [ -n "$backup_file" ]; then
    if [ -f "$backup_file" ]; then
        echo "    The backup of what was there: $(pwd)/$backup_file"
        echo "    (to undo: sudo ./restore.sh $backup_file - copy it off the server before you delete it)"
    else
        warn "The backup recorded before the reset is no longer in $(pwd)/$backup_file."
    fi
fi
if [ "$env_name" = "production" ] && [ -n "$(env_get TEST_DIR)" ]; then
    echo
    echo "To empty testing the same way, copy production into it:"
    echo "    sudo $(env_get TEST_DIR)/Inventory_Shipment/deploy/copy-production-to-testing.sh"
fi
