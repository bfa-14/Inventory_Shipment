#!/usr/bin/env bash
# Deploys the latest code of both repositories.
#
#   sudo ./update.sh
#
# Backs up the database first, pulls this repository and the frontend, rebuilds the images and
# restarts what changed. The API applies Schema.sql as it starts, so database changes need no step
# of their own. Users see a short "server not reachable" message while the API restarts.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ -f .env ] || die "No deploy/.env - run setup.sh first."

if [ -n "$(docker compose ps -q --status running db)" ]; then
    ./backup.sh
fi

say "Pulling the latest code"
git -C .. pull --ff-only
git -C "$(web_dir)" pull --ff-only

say "Building"
docker compose build --pull

say "Restarting what changed"
docker compose up -d
wait_for_api

docker image prune -f >/dev/null
say "Updated: https://$(env_get DOMAIN)"
