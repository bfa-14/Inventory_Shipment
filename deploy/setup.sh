#!/usr/bin/env bash
# Installation of Inventory & Shipment on a Linux server (Ubuntu or Debian). See README.md.
#
#   sudo ./setup.sh            production: the first installation, in /opt/inventory
#   sudo ./setup.sh testing    then, from that same production folder: adds the testing environment
#                              (/opt/inventory-test, main branch, its own database, test.<domain>)
#
# Production: installs Docker when it is missing, checks out the frontend next to this repository, writes
# deploy/.env with fresh secrets (asking for the domain and an email address), builds and starts the stack
# (with the proxy that serves both environments' addresses) and schedules a daily database backup.
# Running it again is safe: an existing .env is kept as it is.
#
# Without a terminal (or to skip the questions) pass the answers in the environment:
#   sudo DOMAIN=erp.example.com ACME_EMAIL=me@example.com ./setup.sh
#   sudo COPY_PRODUCTION_DATA=yes ./setup.sh testing
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root

FRONTEND_REPO=${FRONTEND_REPO:-https://github.com/bfa-14/Inventory_Shipment_Frontend.git}

mode=${1:-}
case "$mode" in
    "" | testing) ;;
    *) die "Usage: $0 [testing]" ;;
esac

# ----- The machine -----------------------------------------------------------------------------

[ "$(uname -m)" = "x86_64" ] || die "SQL Server runs only on x86_64 (amd64) servers, and this one is $(uname -m)."

mem_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
[ "$mem_mb" -ge 1900 ] || die "SQL Server needs at least 2 GB of memory; this server has ${mem_mb} MB."

# Below 4 GB the build plus SQL Server can run the server out of memory; a swap file absorbs the peak.
if [ "$mem_mb" -lt 3800 ] && [ -z "$(swapon --noheadings 2>/dev/null)" ] && [ ! -e /swapfile ]; then
    say "Only ${mem_mb} MB of memory and no swap: adding a 4 GB swap file."
    if fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        rm -f /swapfile
        warn "Could not add a swap file; continuing without one."
    fi
fi

if ! command -v git >/dev/null || ! command -v curl >/dev/null; then
    say "Installing git and curl..."
    apt-get update -qq && apt-get install -y -qq git curl ca-certificates >/dev/null
fi

if ! command -v docker >/dev/null; then
    say "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "Docker is installed but the 'docker compose' plugin is not. Install docker-compose-plugin."
systemctl enable --now docker >/dev/null 2>&1 || true

# ----- deploy/.env -----------------------------------------------------------------------------

# random N - N letters and digits from /dev/urandom.
random() {
    local pool
    pool=$(head -c 2000 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
    printf '%s' "${pool:0:$1}"
}

ask() {
    local prompt=$1 default=${2:-} answer=""
    [ -r /dev/tty ] || die "No terminal to ask \"$prompt\" - pass the answer in the environment (see the top of setup.sh)."
    if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " answer </dev/tty
    else
        read -rp "$prompt: " answer </dev/tty
    fi
    printf '%s' "${answer:-$default}"
}

public_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{ print $1 }')

# ----- setup.sh testing: the second environment, run from the production checkout ---------------

if [ "$mode" = "testing" ]; then
    [ -f .env ] || die "Install production first (sudo ./setup.sh), then run this again."
    ensure_env_defaults
    [ "$(environment)" = "production" ] \
        || die "Run 'setup.sh testing' in the PRODUCTION checkout's deploy folder (/opt/inventory/Inventory_Shipment/deploy)."

    prod_repo=$(cd .. && pwd)
    prod_domain=$(env_get DOMAIN)
    test_domain=$(env_get TEST_DOMAIN)
    test_dir=${TEST_DIR:-$(env_get TEST_DIR /opt/inventory-test)}
    test_branch=${TEST_BRANCH:-main}
    test_web_port=$(env_get TEST_TUNNEL_PORT 8081)
    test_api_port=$(env_get TEST_API_PORT 5081)
    api_repo=$(git -C .. remote get-url origin)
    web_repo=$(git -C "$(web_dir)" remote get-url origin 2>/dev/null || echo "$FRONTEND_REPO")

    [ "$mem_mb" -ge 5500 ] || warn "Two environments run two SQL Servers: ${mem_mb} MB of memory is tight (6 GB or more is comfortable)."

    say "Testing environment: $test_dir ($test_branch branch), https://$test_domain"
    mkdir -p "$test_dir"
    [ -d "$test_dir/Inventory_Shipment/.git" ] || git clone --branch "$test_branch" "$api_repo" "$test_dir/Inventory_Shipment"
    [ -d "$test_dir/Inventory_Shipment_Frontend/.git" ] || git clone --branch "$test_branch" "$web_repo" "$test_dir/Inventory_Shipment_Frontend"
    test_deploy="$test_dir/Inventory_Shipment/deploy"
    grep -q PROXY_REPLICAS "$test_deploy/docker-compose.yml" 2>/dev/null \
        && grep -q environment.json "$test_dir/Inventory_Shipment_Frontend/Caddyfile" 2>/dev/null \
        || die "The $test_branch branch does not have the two-environment deployment files yet: merge them into it first."

    if [ ! -f "$test_deploy/.env" ]; then
        say "Writing $test_deploy/.env"
        umask 077
        cat > "$test_deploy/.env" <<ENV
# Written by setup.sh testing on $(date -u '+%Y-%m-%d %H:%M UTC'). Every setting is described in .env.example.
COMPOSE_PROJECT_NAME=inventory-test
ENVIRONMENT=testing
DOMAIN=${test_domain}
TEST_DOMAIN=${test_domain}
ACME_EMAIL=$(env_get ACME_EMAIL)
SWITCH_URL=https://${prod_domain}
PRODUCTION_DIR=${prod_repo}
PROXY_REPLICAS=0
TUNNEL_PORT=${test_web_port}
API_PORT=${test_api_port}
MSSQL_SA_PASSWORD=$(random 24)Aa1
JWT_SECRET_KEY=$(random 64)
ADMIN_PASSWORD=$(random 12)-Aa1
# Emails of testing are never sent to real people. Set one address here to receive them all, then
# docker compose up -d (in this folder).
TEST_EMAIL_REDIRECT_TO=
ENV
        umask 022
    else
        say "Keeping the existing $test_deploy/.env"
    fi

    # Production learns where testing is: the sign-in page's switch, and update / deploy commands.
    env_set SWITCH_URL "https://$test_domain"
    env_set TEST_DIR "$test_dir"

    "$test_deploy/setup.sh"

    say "Restarting production's web app with the switch to testing"
    docker compose up -d
    wait_for_api

    copy=${COPY_PRODUCTION_DATA:-}
    if [ -z "$copy" ]; then
        if [ -r /dev/tty ]; then
            copy=$(ask "Copy the production database into testing now (yes/no)" yes)
        else
            copy=no
        fi
    fi
    if [ "$copy" = "yes" ] || [ "$copy" = "y" ]; then
        "$test_deploy/copy-production-to-testing.sh" --yes
        echo "Testing now holds a copy of production: sign in to it with your production accounts."
    else
        echo "Testing starts with an empty database. To copy production into it later:"
        echo "    sudo $test_deploy/copy-production-to-testing.sh"
    fi

    echo
    say "Production: https://$prod_domain   (production branch, $prod_repo)"
    say "Testing:    https://$test_domain   ($test_branch branch, $test_dir)"
    echo "The switch on the sign-in page moves between the two. Emails of testing are never sent to"
    echo "real people (TEST_EMAIL_REDIRECT_TO in $test_deploy/.env sends them all to one address)."
    exit 0
fi

if [ ! -f .env ]; then
    say "Writing deploy/.env"
    domain=${DOMAIN:-}
    if [ -z "$domain" ]; then
        echo "The site's address. Point the domain's DNS A record at ${public_ip} first."
        echo "No domain yet? Keep the suggested ${public_ip//./-}.sslip.io - it reaches this server and gets a real certificate."
        domain=$(ask "Domain" "${public_ip//./-}.sslip.io")
    fi
    domain=${domain#https://}; domain=${domain#http://}; domain=${domain%%/*}

    email=${ACME_EMAIL:-}
    while [ -z "$email" ]; do
        email=$(ask "Email address for Let's Encrypt certificate notices")
    done

    # Upper case, lower case and a digit (SQL Server's rule); the admin password also needs a symbol.
    umask 077
    cat > .env <<ENV
# Written by setup.sh on $(date -u '+%Y-%m-%d %H:%M UTC'). Every setting is described in .env.example.
ENVIRONMENT=production
DOMAIN=${domain}
TEST_DOMAIN=test.${domain}
ACME_EMAIL=${email}
MSSQL_SA_PASSWORD=$(random 24)Aa1
JWT_SECRET_KEY=$(random 64)
ADMIN_PASSWORD=$(random 12)-Aa1
ENV
    umask 022
    first_install=1
else
    say "Keeping the existing deploy/.env"
    first_install=0
fi

ensure_env_defaults
env_name=$(environment)
domain=$(env_get DOMAIN)
[ -n "$domain" ] || die "DOMAIN is empty in deploy/.env."

# Let's Encrypt can only issue a certificate for an address that already reaches this server. Production's
# proxy serves both addresses, so it checks the testing one too.
check_dns() {
    local name=$1 resolved
    resolved=$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
    if [ -z "$resolved" ]; then
        warn "$name does not resolve yet. HTTPS starts working once its DNS A record points at ${public_ip}."
    elif [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
        warn "$name points at $resolved, but this server is ${public_ip}. HTTPS will not work until DNS is fixed."
    fi
}
check_dns "$domain"
[ "$env_name" = "production" ] && check_dns "$(env_get TEST_DOMAIN)"

# ----- The frontend source ---------------------------------------------------------------------

web=$(web_dir)
if [ ! -d "$web/.git" ]; then
    # The branch this repository is on, when the frontend has one of the same name; else its default.
    branch=$(git -C .. rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
    if git ls-remote --exit-code --heads "$FRONTEND_REPO" "$branch" >/dev/null 2>&1; then
        say "Cloning the frontend ($branch) into $web"
        git clone --branch "$branch" "$FRONTEND_REPO" "$web"
    else
        say "Cloning the frontend into $web"
        git clone "$FRONTEND_REPO" "$web"
    fi
fi
[ -f "$web/Dockerfile" ] || die "$web has no Dockerfile - check out a version of the frontend that includes the deployment files."

# ----- Firewall --------------------------------------------------------------------------------

# Only touched when it is already on: turning it on here could lock out an SSH session on another port.
if [ "$env_name" = "production" ] && command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
    say "Opening ports 80 and 443 in ufw"
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
fi

# ----- Start -----------------------------------------------------------------------------------

ensure_backup_dir

say "Building and starting (the first build takes several minutes)..."
docker compose up -d --build
wait_for_api

# ----- Daily backup ----------------------------------------------------------------------------

# One schedule per environment: production at 02:30, testing at 02:45.
if [ "$env_name" = "production" ]; then
    cron_file=/etc/cron.d/inventory-shipment-backup; cron_minute=30
else
    cron_file=/etc/cron.d/inventory-shipment-backup-$env_name; cron_minute=45
fi
if [ -d /etc/cron.d ]; then
    cat > "$cron_file" <<CRON
# Inventory & Shipment ($env_name): database backup every night at 02:$cron_minute (server time) into $(pwd)/backups.
$cron_minute 2 * * * root $(pwd)/backup.sh >> /var/log/inventory-shipment-backup-$env_name.log 2>&1
CRON
    chmod 644 "$cron_file"
else
    warn "No /etc/cron.d: schedule $(pwd)/backup.sh yourself."
fi

# ----- Done ------------------------------------------------------------------------------------

echo
say "Inventory & Shipment ($env_name) is running at https://${domain}"
if [ "$first_install" -eq 1 ]; then
    echo
    echo "    Sign in with:   admin / $(env_get ADMIN_PASSWORD)"
    echo
    echo "    Change that password right after signing in. It is also kept in $(pwd)/.env."
fi
echo
echo "The HTTPS certificate can take a minute to arrive. If the page still does not open, see"
echo "\"The site does not open\" in deploy/README.md."
