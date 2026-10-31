#!/usr/bin/env bash
# One-time setup for the "Deploy to server" button (.github/workflows/deploy.yml in both repositories): a person
# presses Run workflow - on GitHub, in VS Code or in Visual Studio - and picks testing or production. A push
# deploys nothing (README.md, "Deploying with a button").
#
#   sudo ./enable-github-deploy.sh        in the PRODUCTION checkout's deploy folder
#
# Installs /usr/local/sbin/inventory-deploy (production | testing: runs that environment's update.sh), creates
# an SSH key that can do exactly one thing on this server, run that command, and prints the values to save
# as secrets in BOTH GitHub repositories. Also lets this user run the command with sudo without a password,
# which the key needs. Running it again replaces the key (the old one stops working) and the command (after
# setting up the testing environment, for example).
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root

ensure_env_defaults
[ "$(environment)" = "production" ] \
    || die "Run it in the PRODUCTION checkout's deploy folder (/opt/inventory/Inventory_Shipment/deploy)."

user=${SUDO_USER:-root}
group=$(id -gn "$user")
home=$(getent passwd "$user" | cut -d: -f6)
marker="inventory-shipment-github-deploy"
command_path=/usr/local/sbin/inventory-deploy
production_deploy=$(pwd)
testing_deploy="$(env_get TEST_DIR /opt/inventory-test)/Inventory_Shipment/deploy"

# Whoever can change these files could run anything as root through the key: they must be root's alone.
check_root_only() {
    local dir=$1 path
    for path in "$dir/.." "$dir" "$dir/update.sh" "$dir/lib.sh" "$dir/backup.sh"; do
        [ "$(stat -c %u "$path")" = "0" ] && [ -z "$(find "$path" -maxdepth 0 -perm /022)" ] \
            || die "$(realpath "$path") must be owned by root and writable only by root (clone the repository with sudo)."
    done
}
check_root_only "$production_deploy"
[ -d "$testing_deploy" ] && check_root_only "$testing_deploy"

# The one command the key can run. Root's, outside both checkouts: a pull cannot change what it allows.
#
# THE DEPLOYMENT DOES NOT HANG ON THE SSH CONNECTION. Its output goes through tee into a log on the server;
# tee ignores a closed connection (a cancelled or timed-out GitHub job) and keeps writing the log, so the
# update always runs to its end instead of dying at its next line of output, half done.
tmp_command=$(mktemp)
cat > "$tmp_command" <<COMMAND
#!/bin/bash
# Written by $(realpath "$0"): deploys one environment of Inventory & Shipment.
# The GitHub deploy key can run this command and nothing else. Log: /var/log/inventory-deploy-<environment>.log
set -o pipefail
case "\$1" in
    production) deploy=$production_deploy ;;
    testing)
        deploy=$testing_deploy
        [ -x "\$deploy/update.sh" ] || { echo "The testing environment is not set up on this server (setup.sh testing)." >&2; exit 1; } ;;
    *) echo "Usage: inventory-deploy production|testing" >&2; exit 2 ;;
esac
echo "=== \$(date -u '+%Y-%m-%d %H:%M:%S UTC') deploying \$1" >> "/var/log/inventory-deploy-\$1.log"
"\$deploy/update.sh" 2>&1 | tee --output-error=warn-nopipe -a "/var/log/inventory-deploy-\$1.log"
COMMAND
install -m 755 -o root -g root "$tmp_command" "$command_path"
rm -f "$tmp_command"

[ -r /etc/ssh/ssh_host_ed25519_key.pub ] || die "No /etc/ssh/ssh_host_ed25519_key.pub: is the SSH server installed?"
port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
port=${port:-22}
host=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{ print $1 }')
if [ "$port" = "22" ]; then known_host=$host; else known_host="[$host]:$port"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "$marker" -f "$tmp/key"

# The key's line in authorized_keys: whatever the client asks for, inventory-deploy runs ("command="), with
# what the client sent as its one argument (production or testing; anything else is refused), and
# "restrict" takes away port forwarding, a terminal and everything else.
if [ "$user" = "root" ]; then command="$command_path \\\"\$SSH_ORIGINAL_COMMAND\\\""; else command="sudo -n $command_path \\\"\$SSH_ORIGINAL_COMMAND\\\""; fi
install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -v " $marker\$" "$home/.ssh/authorized_keys" > "$tmp/authorized_keys" || true
printf 'command="%s",restrict %s\n' "$command" "$(cat "$tmp/key.pub")" >> "$tmp/authorized_keys"
install -m 600 -o "$user" -g "$group" "$tmp/authorized_keys" "$home/.ssh/authorized_keys"

if [ "$user" != "root" ]; then
    printf '# Written by %s: lets the GitHub deploy key run inventory-deploy.\n%s ALL=(root) NOPASSWD: %s\n' \
        "$(realpath "$0")" "$user" "$command_path" > "$tmp/sudoers"
    visudo -cqf "$tmp/sudoers" || die "The sudo rule did not validate."
    install -m 440 -o root -g root "$tmp/sudoers" /etc/sudoers.d/inventory-shipment-deploy
fi

cat <<EOF

$(say "Done. Now save these as secrets on GitHub, in BOTH repositories:")

  github.com/bfa-14/Inventory_Shipment          > Settings > Secrets and variables > Actions > New repository secret
  github.com/bfa-14/Inventory_Shipment_Frontend > Settings > Secrets and variables > Actions > New repository secret

  Name                 Value
  -------------------  ----------------------------------------------------------
  DEPLOY_HOST          $host
  DEPLOY_USER          $user
EOF
[ "$port" = "22" ] || echo "  DEPLOY_PORT          $port"
cat <<EOF
  DEPLOY_KNOWN_HOSTS   $known_host $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)
  DEPLOY_SSH_KEY       everything between the two lines below, BEGIN and END lines included:

-----------------------------------------------------------------------------------------------
$(cat "$tmp/key")
-----------------------------------------------------------------------------------------------

This key is shown only now and is not kept on the server. Never paste it anywhere but those secrets.

From then on deploy with the button - it never runs by itself: Actions tab > "Deploy to server" > Run
workflow (or the same button in VS Code or Visual Studio: README.md, "Deploying with a button"), choosing
testing or production (production asks you to type production again). Or from your PC:
    ssh -t $user@$host sudo $command_path testing
Each deployment is also logged on the server: /var/log/inventory-deploy-production.log / -testing.log
EOF
