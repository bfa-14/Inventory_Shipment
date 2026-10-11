#!/usr/bin/env bash
# Deploys the latest code of both repositories, in the environment of this checkout.
#
#   sudo ./update.sh                the branch this checkout is on: production in /opt/inventory,
#                                   main in /opt/inventory-test (the testing environment)
#   sudo ./update.sh production     switch both repositories to that branch first, then deploy it
#
# Backs up the database first, pulls this repository and the frontend, rebuilds the images and
# restarts what changed. The API applies Schema.sql as it starts, so database changes need no step
# of their own. Users see a short "server not reachable" message while the API restarts.
#
# The GitHub "Deploy to server" workflow runs this same script (see "Deploy new versions" in README.md).
# Two updates of the same environment never run at once: the second waits for the first.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ -f .env ] || die "No deploy/.env - run setup.sh first."
ensure_env_defaults

web=$(web_dir)
env_name=$(environment)

if [ "${UPDATE_STAGE:-}" != "build" ]; then
    # Held until this script ends, across the exec below (the backend and the frontend repositories can
    # both start a deployment of the same environment at the same moment).
    exec 9>"/run/lock/inventory-update-$env_name.lock"
    if ! flock -n 9; then
        say "Another update of $env_name is running: waiting for it to finish..."
        flock -w 1800 9 || die "The other update of $env_name has not finished after 30 minutes."
    fi

    branch=${1:-}
    if [ -n "$branch" ]; then
        # Everything is checked before either repository moves, so a wrong name changes nothing.
        [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Not a branch name: $branch"
        for repo in .. "$web"; do
            git -C "$repo" fetch --quiet origin "$branch" 2>/dev/null \
                || die "$(basename "$(git -C "$repo" rev-parse --show-toplevel)") has no branch '$branch' on GitHub."
        done
        git -C .. cat-file -e "origin/$branch:deploy/update.sh" 2>/dev/null \
            && git -C "$web" cat-file -e "origin/$branch:Dockerfile" 2>/dev/null \
            || die "'$branch' does not have the deployment files (deploy/, Dockerfile) in both repositories yet - merge them into it first."
    fi

    if [ -n "$(docker compose ps -q --status running db)" ]; then
        ./backup.sh
    fi

    for repo in .. "$web"; do
        name=$(basename "$(git -C "$repo" rev-parse --show-toplevel)")
        if [ -n "$branch" ] && [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" != "$branch" ]; then
            say "Switching $name to $branch"
            git -C "$repo" checkout --quiet -B "$branch" --track "origin/$branch"
        fi
        current=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
        say "Pulling $name ($current)"
        git -C "$repo" pull --ff-only \
            || die "$name on the server cannot simply move forward to GitHub's $current (its history was rewritten,
       or files were edited on the server). To make the server's copy exactly GitHub's, then deploy again:
           sudo git -C $(realpath "$repo") reset --hard origin/$current"
    done

    if [ "$env_name" = "production" ] && [ "$(git -C .. rev-parse --abbrev-ref HEAD)" != "production" ]; then
        warn "Production runs the $(git -C .. rev-parse --abbrev-ref HEAD) branch. It should follow the production branch: sudo ./update.sh production"
    fi

    # The pull may have brought a new version of this script: carry on with that one.
    UPDATE_STAGE=build exec ./update.sh
fi

say "Building"
docker compose build --pull

say "Restarting what changed"
docker compose up -d
wait_for_api

docker image prune -f >/dev/null
say "Updated $env_name: https://$(env_get DOMAIN)"
for repo in .. "$web"; do
    echo "    $(basename "$(git -C "$repo" rev-parse --show-toplevel)"): $(git -C "$repo" log -1 --format='%h %s (%cr)')"
done
