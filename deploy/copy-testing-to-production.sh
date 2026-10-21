#!/usr/bin/env bash
# Replaces the PRODUCTION database with a copy of testing's, taken now: to go live with what was entered in testing.
#
#   sudo ./copy-testing-to-production.sh      in the PRODUCTION checkout's deploy folder
#                                             (/opt/inventory/Inventory_Shipment/deploy)
#
# ONLY WHEN PRODUCTION RUNS THE SAME CODE AS TESTING (both repositories): production's API would otherwise apply an older
# schema to the newer database. Release main to production first (README.md, "Branches and deploying").
#
# Backs up production first and keeps that backup in deploy/backups/before-copy-from-testing (not pruned like the
# nightly ones), backs up testing (which is only read), and restores testing's backup into production (restore.sh).
# Before production's API starts on it: the "Address of the application" points at production, the emails testing
# still had to send are closed (never sent from production), and everyone signs in again (a new signing key). The
# users and passwords are testing's. The SMTP password does not come along (it is encrypted with testing's keys):
# type it again in Settings > Email.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ -f .env ] || die "No deploy/.env - run setup.sh first."
ensure_env_defaults
[ "$(environment)" = "production" ] \
    || die "This replaces the PRODUCTION database: run it in production's deploy folder (/opt/inventory/Inventory_Shipment/deploy)."
[ $# -eq 0 ] || die "Usage: $0"

test_deploy="$(env_get TEST_DIR /opt/inventory-test)/Inventory_Shipment/deploy"
[ -f "$test_deploy/.env" ] && [ -x "$test_deploy/backup.sh" ] \
    || die "No testing checkout at $test_deploy (TEST_DIR in deploy/.env)."
db=$(db_name)
test_db=$(cd "$test_deploy" && db_name)
domain=$(env_get DOMAIN)
test_domain=$(cd "$test_deploy" && env_get DOMAIN)

# THE SAME CODE ON BOTH SIDES. Their trees are compared: a release merge gives production a commit of its own with the
# same files.
for pair in "..|$test_deploy/.." "$(realpath "$(web_dir)")|$(cd "$test_deploy" && realpath "$(web_dir)")"; do
    mine=${pair%%|*}; theirs=${pair#*|}
    if [ "$(git -C "$mine" rev-parse 'HEAD^{tree}')" != "$(git -C "$theirs" rev-parse 'HEAD^{tree}')" ]; then
        die "$(basename "$(git -C "$mine" rev-parse --show-toplevel)") differs: production runs '$(git -C "$mine" log -1 --format='%h %s')', testing '$(git -C "$theirs" log -1 --format='%h %s')'. Release main to production first (README.md, \"Branches and deploying\"). Nothing was changed."
    fi
done

# A REAL TERMINAL: this replaces production's data, and nothing scripted should do it by accident.
{ true </dev/tty; } 2>/dev/null || die "Run this from a terminal: it asks for a confirmation."
echo
echo "This REPLACES the PRODUCTION database ($db of https://$domain) with a copy of testing's ($test_db,"
echo "https://$test_domain), taken now. Everything entered in production since then is replaced; a backup of it"
echo "is taken first. Everyone is signed out."
read -t 300 -rp "Type the address $domain to continue: " answer </dev/tty || die "Cancelled (no answer): nothing was changed."
[ "$answer" = "$domain" ] || die "Cancelled: nothing was changed."

# Testing's lock, then production's: the order of every script that takes both.
exec 7>"/run/lock/inventory-update-testing.lock"
if ! flock -n 7; then
    say "Testing is being updated, restored, copied or reset: waiting for it to finish..."
    flock -w 1800 7 || die "Testing is still busy after 30 minutes. Nothing was changed."
fi
take_env_lock

say "Backing up production"
./backup.sh
latest=$(find backups -maxdepth 1 -name "$db-*.bak.gz" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
[ -n "$latest" ] || die "The backup of production was not found in deploy/backups: nothing was changed."
mkdir -p backups/before-copy-from-testing
ln -f "$latest" backups/before-copy-from-testing/ 2>/dev/null || cp -p "$latest" backups/before-copy-from-testing/
kept="backups/before-copy-from-testing/${latest##*/}"

say "Backing up testing"
"$test_deploy/backup.sh"
source_file=$(find "$test_deploy/backups" -maxdepth 1 -name "$test_db-*.bak.gz" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
[ -n "$source_file" ] || die "The backup of testing was not found in $test_deploy/backups: nothing was changed."

# A new signing key: a sign-in made in production before carries a user id that now means someone else, or nobody.
# restore.sh starts the API with it ("up", not "start").
env_set JWT_SECRET_KEY "$(head -c 2000 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 64)"

RESTORE_THEN_SQL="SET NOCOUNT ON;
IF COL_LENGTH(N'messaging.EmailSettings', N'PublicBaseUrl') IS NOT NULL
    UPDATE messaging.EmailSettings SET PublicBaseUrl = N'https://$domain' WHERE PublicBaseUrl IS NOT NULL;
IF OBJECT_ID(N'messaging.EmailOutbox', N'U') IS NOT NULL
    UPDATE messaging.EmailOutbox SET Status = 3, LastError = N'Copied from testing: never sent from production.'
    WHERE Status = 1;
IF OBJECT_ID(N'security.RefreshTokens', N'U') IS NOT NULL
    DELETE FROM security.RefreshTokens;" \
    ./restore.sh --yes "$source_file"

echo
say "Production now holds a copy of testing from $(basename "$source_file" .bak.gz | sed 's/.*-\([0-9]\{8\}\)-\([0-9]\{6\}\)$/\1 \2 UTC/')."
echo "    Sign in with a testing account (everyone was signed out)."
echo "    Type the SMTP password again in Configuration > Settings > Email: it did not come along."
echo "    Production as it was: $(pwd)/$kept (to undo: sudo ./restore.sh $kept)"
