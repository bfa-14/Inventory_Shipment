#!/usr/bin/env bash
# First-time installation of Inventory & Shipment on a Linux server (Ubuntu or Debian). See README.md.
#
#   sudo ./setup.sh
#
# Installs Docker when it is missing, checks out the frontend next to this repository, writes deploy/.env
# with fresh secrets (asking for the domain and an email address), builds and starts the stack, and
# schedules a daily database backup. Running it again is safe: an existing .env is kept as it is.
#
# Without a terminal (or to skip the questions) pass the answers in the environment:
#   sudo DOMAIN=erp.example.com ACME_EMAIL=me@example.com ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root

FRONTEND_REPO=${FRONTEND_REPO:-https://github.com/bfa-14/Inventory_Shipment_Frontend.git}

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
DOMAIN=${domain}
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

domain=$(env_get DOMAIN)
[ -n "$domain" ] || die "DOMAIN is empty in deploy/.env."

# Let's Encrypt can only issue the certificate when the domain already reaches this server.
resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
if [ -z "$resolved" ]; then
    warn "$domain does not resolve yet. HTTPS starts working once its DNS A record points at ${public_ip}."
elif [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
    warn "$domain points at $resolved, but this server is ${public_ip}. HTTPS will not work until DNS is fixed."
fi

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
if command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
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

if [ -d /etc/cron.d ]; then
    cat > /etc/cron.d/inventory-shipment-backup <<CRON
# Inventory & Shipment: database backup every night at 02:30 (server time) into $(pwd)/backups.
30 2 * * * root $(pwd)/backup.sh >> /var/log/inventory-shipment-backup.log 2>&1
CRON
    chmod 644 /etc/cron.d/inventory-shipment-backup
else
    warn "No /etc/cron.d: schedule $(pwd)/backup.sh yourself."
fi

# ----- Done ------------------------------------------------------------------------------------

echo
say "Inventory & Shipment is running at https://${domain}"
if [ "$first_install" -eq 1 ]; then
    echo
    echo "    Sign in with:   admin / $(env_get ADMIN_PASSWORD)"
    echo
    echo "    Change that password right after signing in. It is also kept in $(pwd)/.env."
fi
echo
echo "The HTTPS certificate can take a minute to arrive. If the page still does not open, see"
echo "\"The site does not open\" in deploy/README.md."
