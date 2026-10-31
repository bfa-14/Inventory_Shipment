#!/usr/bin/env bash
# Replaces the TESTING database with a copy of production's, taken now.
#
#   sudo ./copy-production-to-testing.sh          in the testing checkout's deploy folder
#                                                 (/opt/inventory-test/Inventory_Shipment/deploy)
#
# Backs up production (backup.sh of the production checkout, PRODUCTION_DIR in deploy/.env), restores that
# backup into testing (restore.sh), and points testing's email links at testing. Testing's API then brings
# the copy up to the main branch's schema as it starts: a rehearsal of the next production update.
#
# Testing on production's SQL Server (README.md, "One SQL Server for both environments") gets the copy the same way,
# into its own database there.
#
# Production is only read. Its users and passwords come along, so testers sign in to testing with their
# production accounts (their sign-ins are not: everyone signs in again). Emails are still never sent to real
# people from testing (App__Environment=testing); the SMTP password does not come along either (it is
# encrypted with production's keys).
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ "$(environment)" = "testing" ] \
    || die "This replaces the TESTING database: run it in the testing checkout (/opt/inventory-test/Inventory_Shipment/deploy)."
assume_yes=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) assume_yes=1 ;;
        *) die "Usage: $0 [--yes]" ;;
    esac
done

production=$(env_get PRODUCTION_DIR /opt/inventory/Inventory_Shipment)
[ -x "$production/deploy/backup.sh" ] || die "No production checkout at $production (PRODUCTION_DIR in deploy/.env)."

# ASKED BEFORE ANY LOCK IS TAKEN, with five minutes to answer: a forgotten question never holds up a deployment.
if [ "$assume_yes" -ne 1 ]; then
    echo "This REPLACES the testing database with a copy of production. Everything entered in testing is lost."
    read -t 300 -rp "Type YES to continue: " answer </dev/tty || die "Cancelled (no answer)."
    [ "$answer" = "YES" ] || die "Cancelled."
fi

# Testing's lock: no deployment of testing starts while its database is being replaced (restore.sh below runs under
# the same lock). PRODUCTION'S LOCK TOO, held to the end: production is not copied in the middle of an update, a
# restore or a reset. Always testing first, then production, as every script that takes both.
take_env_lock
take_production_lock

# A RESET OF PRODUCTION THAT STOPPED HALFWAY (its side database is still there): refused only when production's data
# is really gone - its database deleted, or replaced by the new one not yet finished (newer than the side database and
# not restored since). A reset that stopped before deleting anything, or data restored since, is copied with a warning.
production_db=$(cd "$production/deploy" && db_name)
half_reset=$(cd "$production/deploy" && sql_exec -h -1 -W -Q "SET NOCOUNT ON;
    IF DB_ID(N'${production_db}_reset_keep') IS NULL SELECT 0;
    ELSE IF DB_ID(N'$production_db') IS NULL SELECT 1;
    ELSE IF EXISTS (SELECT 1 FROM msdb.dbo.restorehistory
                    WHERE destination_database_name = N'$production_db'
                      AND restore_date >= (SELECT create_date FROM sys.databases WHERE name = N'${production_db}_reset_keep')) SELECT 2;
    ELSE IF (SELECT create_date FROM sys.databases WHERE name = N'$production_db')
          > (SELECT create_date FROM sys.databases WHERE name = N'${production_db}_reset_keep') SELECT 1;
    ELSE SELECT 2;" | tr -d '[:space:]')
case "$half_reset" in
    0) ;;
    2) warn "Production has a reset that stopped before deleting anything (or its data was restored since): its data is intact and is copied. Production's API may still be stopped: sudo docker compose up -d in $production/deploy. (Running reset-database.sh again starts that reset over.)" ;;
    *) die "Production's reset did not finish: run sudo ./reset-database.sh in $production/deploy again first. Testing was not changed." ;;
esac

say "Backing up production"
"$production/deploy/backup.sh"
latest=$(find "$production/deploy/backups" -maxdepth 1 -name '*.bak.gz' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
[ -n "$latest" ] || die "No production backup found in $production/deploy/backups."

production_domain=$(cd "$production/deploy" && env_get DOMAIN)
testing_domain=$(env_get DOMAIN)

# Run on the copy before testing's API starts on it, so testing never runs with production's settings:
#  - the "Address of the application" (Settings > Email): the links in testing's emails must open testing;
#  - the emails copied from production: their approval links open production, with tokens that work there.
#    They are pointed at testing, and those still waiting to be sent are closed (Failed, with the reason in
#    the Email log), so a tester never acts on production from a testing email;
#  - production's sign-ins (refresh tokens): only someone who knows a current password signs in to testing.
# A NEW SIGNING KEY FOR TESTING: a sign-in made in testing before the copy carries a user id that now means someone
# else, or nobody. restore.sh starts the API with it ("up", not "start").
env_set JWT_SECRET_KEY "$(head -c 2000 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 64)"

RESTORE_THEN_SQL="SET NOCOUNT ON;
IF COL_LENGTH(N'messaging.EmailSettings', N'PublicBaseUrl') IS NOT NULL
    UPDATE messaging.EmailSettings SET PublicBaseUrl = N'https://$testing_domain' WHERE PublicBaseUrl IS NOT NULL;
IF OBJECT_ID(N'messaging.EmailOutbox', N'U') IS NOT NULL
BEGIN
    UPDATE messaging.EmailOutbox SET BodyHtml = REPLACE(BodyHtml, N'https://$production_domain', N'https://$testing_domain')
    WHERE BodyHtml LIKE N'%https://$production_domain%';
    UPDATE messaging.EmailOutbox SET Status = 3, LastError = N'Copied from production: never sent from testing.'
    WHERE Status = 1;
END
IF OBJECT_ID(N'security.RefreshTokens', N'U') IS NOT NULL
    DELETE FROM security.RefreshTokens;" \
    ./restore.sh --yes "$latest"

say "Testing now holds a copy of production from $(basename "$latest" .bak.gz | sed 's/.*-\([0-9]\{8\}\)-\([0-9]\{6\}\)$/\1 \2 UTC/')."
echo "Its users are production's as they are now. A user disabled, or a password changed, in production later"
echo "still works in testing until the next copy: disable or change it in testing too."
