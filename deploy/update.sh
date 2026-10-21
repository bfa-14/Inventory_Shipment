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
# The GitHub "Deploy to server" button runs this same script (README.md, "Deploying with a button"). Two updates
# (or restores) of the same environment never run at once: the second waits.
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
    take_env_lock

    branch=${1:-}
    if [ -n "$branch" ]; then
        # Everything is checked before either repository moves, so a wrong name changes nothing.
        [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Not a branch name: $branch"
        for repo in .. "$web"; do
            git -C "$repo" fetch --quiet origin "$branch" 2>/dev/null \
                || die "$(basename "$(git -C "$repo" rev-parse --show-toplevel)") has no branch '$branch' on GitHub."
        done
        git -C .. cat-file -e "origin/$branch:deploy/proxy/Caddyfile" 2>/dev/null \
            && git -C "$web" show "origin/$branch:Caddyfile" 2>/dev/null | grep -q environment.json \
            || die "'$branch' does not have the two-environment deployment files in both repositories yet - merge main into it first. Nothing was changed."
    else
        # BOTH CHECKOUTS FOLLOW ONE BRANCH, and production follows production: a deployment never mixes
        # the frontend of one branch with the API of another, or sends untested main to production.
        api_branch=$(git -C .. rev-parse --abbrev-ref HEAD)
        web_branch=$(git -C "$web" rev-parse --abbrev-ref HEAD)
        [ "$api_branch" = "$web_branch" ] \
            || die "The API checkout is on $api_branch but the frontend's is on $web_branch: both must follow one branch. Run: sudo ./update.sh $([ "$env_name" = production ] && echo production || echo "$api_branch")"
        if [ "$env_name" = "production" ] && [ "$api_branch" != "production" ]; then
            if git -C .. ls-remote --exit-code --heads origin production >/dev/null 2>&1; then
                die "Production runs the $api_branch branch but must follow the production branch. Run: sudo ./update.sh production"
            fi
            warn "Production runs the $api_branch branch: there is no production branch on GitHub yet."
        fi
    fi

    if sql_running; then
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

# Checked again here: an update.sh from before the two environments may have pulled and exec'd into this one.
require_proxy_web "$web"

# ONE SQL SERVER FOR BOTH ENVIRONMENTS (README.md): testing's login and database in production's SQL Server, as
# testing's deploy/.env says (set again if they drifted); production keeps answering testing on the shared network.
if [ "$env_name" = "testing" ] && shared_sql; then
    require_compose 2.24
    ensure_sql_network
    sql_host_ready \
        || die "Production's SQL Server does not answer testing on the network $SQL_NETWORK. In $(production_deploy): sudo docker compose up -d db (its COMPOSE_FILE must list $SQL_HOST_FILE), then run this again."
    ensure_shared_database
elif [ "$env_name" = "production" ] && testing_shares_sql; then
    write_sql_host "$(pwd)"
    ensure_sql_network
fi

say "Building"
docker compose build --pull

if [ "$env_name" = "production" ]; then
    open_web_ports
fi

say "Restarting what changed"
docker compose up -d

# The proxy keeps the configuration it started with: a pulled change to proxy/Caddyfile is checked, then
# loaded without dropping connections. Caddy skips an unchanged one, and a refused file leaves the running
# configuration in place.
if [ "$env_name" = "production" ] && [ -n "$(docker compose ps -q --status running proxy)" ]; then
    docker compose exec -T proxy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
        || { docker compose exec -T proxy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >&2 || true
             die "proxy/Caddyfile is not valid (above): the proxy keeps its previous configuration. Fix the file and run this again."; }
    loaded=""
    for _ in $(seq 1 10); do
        # A proxy that has only just started may not listen for its configuration yet.
        if docker compose exec -T proxy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
            loaded=1
            break
        fi
        sleep 3
    done
    [ -n "$loaded" ] || die "The proxy did not take its configuration (docker compose logs proxy)."
fi

wait_for_api
wait_for_web

docker image prune -f >/dev/null
say "Updated $env_name: https://$(env_get DOMAIN)"
for repo in .. "$web"; do
    echo "    $(basename "$(git -C "$repo" rev-parse --show-toplevel)"): $(git -C "$repo" log -1 --format='%h %s (%cr)')"
done
