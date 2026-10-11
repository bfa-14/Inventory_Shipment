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
# Testing's lock: no deployment of testing starts while its database is being replaced (restore.sh below
# runs under the same lock).
take_env_lock

assume_yes=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) assume_yes=1 ;;
        *) die "Usage: $0 [--yes]" ;;
    esac
done

production=$(env_get PRODUCTION_DIR /opt/inventory/Inventory_Shipment)
[ -x "$production/deploy/backup.sh" ] || die "No production checkout at $production (PRODUCTION_DIR in deploy/.env)."

if [ "$assume_yes" -ne 1 ]; then
    echo "This REPLACES the testing database with a copy of production. Everything entered in testing is lost."
    read -rp "Type YES to continue: " answer </dev/tty
    [ "$answer" = "YES" ] || die "Cancelled."
fi

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
