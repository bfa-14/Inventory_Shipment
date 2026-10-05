#!/usr/bin/env bash
# Deploys the latest code of both repositories.
#
#   sudo ./update.sh            the branch the server is on (normally main)
#   sudo ./update.sh main       switch both repositories to that branch first, then deploy it
#
# Backs up the database first, pulls this repository and the frontend, rebuilds the images and
# restarts what changed. The API applies Schema.sql as it starts, so database changes need no step
# of their own. Users see a short "server not reachable" message while the API restarts.
#
# The "Deploy to server" button on GitHub runs this same script (see "Deploy new versions" in README.md).
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
[ -f .env ] || die "No deploy/.env - run setup.sh first."

web=$(web_dir)

if [ "${UPDATE_STAGE:-}" != "build" ]; then
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

    # The pull may have brought a new version of this script: carry on with that one.
    UPDATE_STAGE=build exec ./update.sh
fi

say "Building"
docker compose build --pull

say "Restarting what changed"
docker compose up -d
wait_for_api

docker image prune -f >/dev/null
say "Updated: https://$(env_get DOMAIN)"
for repo in .. "$web"; do
    echo "    $(basename "$(git -C "$repo" rev-parse --show-toplevel)"): $(git -C "$repo" log -1 --format='%h %s (%cr)')"
done
