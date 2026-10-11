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
# production accounts. Emails are still never sent to real people from testing (App__Environment=testing);
# the SMTP password does not come along either (it is encrypted with production's keys).
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

if [ "$assume_yes" -ne 1 ]; then
    echo "This REPLACES the testing database with a copy of production. Everything entered in testing is lost."
    read -rp "Type YES to continue: " answer </dev/tty
    [ "$answer" = "YES" ] || die "Cancelled."
fi

say "Backing up production"
"$production/deploy/backup.sh"
latest=$(find "$production/deploy/backups" -maxdepth 1 -name '*.bak.gz' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
[ -n "$latest" ] || die "No production backup found in $production/deploy/backups."

./restore.sh --yes "$latest"

# The copy carries production's "Address of the application" (Settings > Email): the links in testing's
# emails must open testing.
say "Pointing testing's email links at https://$(env_get DOMAIN)"
sql_exec -d "$(db_name)" -Q "IF COL_LENGTH(N'messaging.EmailSettings', N'PublicBaseUrl') IS NOT NULL
    UPDATE messaging.EmailSettings SET PublicBaseUrl = N'https://$(env_get DOMAIN)' WHERE PublicBaseUrl IS NOT NULL;"
docker compose restart api
wait_for_api

say "Testing now holds a copy of production from $(basename "$latest" .bak.gz | sed 's/.*-\([0-9]\{8\}\)-\([0-9]\{6\}\)$/\1 \2 UTC/')."
