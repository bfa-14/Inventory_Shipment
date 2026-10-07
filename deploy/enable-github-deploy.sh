#!/usr/bin/env bash
# One-time setup for the "Deploy to server" button on GitHub (.github/workflows/deploy.yml).
#
#   sudo ./enable-github-deploy.sh
#
# Creates an SSH key that can do exactly one thing on this server, run update.sh, and prints the values
# to save as secrets in the GitHub repository. Also lets this user run update.sh with sudo without a
# password, which the key needs. Running it again replaces the key; the old one stops working.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root

user=${SUDO_USER:-root}
group=$(id -gn "$user")
home=$(getent passwd "$user" | cut -d: -f6)
script="$(pwd)/update.sh"
marker="inventory-shipment-github-deploy"

# Whoever can change these files could run anything as root through the key: they must be root's alone.
for path in .. . ./update.sh ./lib.sh ./backup.sh; do
    [ "$(stat -c %u "$path")" = "0" ] && [ -z "$(find "$path" -maxdepth 0 -perm /022)" ] \
        || die "$(realpath "$path") must be owned by root and writable only by root (clone the repository with sudo)."
done

[ -r /etc/ssh/ssh_host_ed25519_key.pub ] || die "No /etc/ssh/ssh_host_ed25519_key.pub: is the SSH server installed?"
port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
port=${port:-22}
host=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{ print $1 }')
if [ "$port" = "22" ]; then known_host=$host; else known_host="[$host]:$port"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "$marker" -f "$tmp/key"

# The key's line in authorized_keys: whatever command the client asks for, update.sh runs ("command="),
# and "restrict" takes away port forwarding, a terminal and everything else.
if [ "$user" = "root" ]; then command=$script; else command="sudo -n $script"; fi
install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -v " $marker\$" "$home/.ssh/authorized_keys" > "$tmp/authorized_keys" || true
printf 'command="%s",restrict %s\n' "$command" "$(cat "$tmp/key.pub")" >> "$tmp/authorized_keys"
install -m 600 -o "$user" -g "$group" "$tmp/authorized_keys" "$home/.ssh/authorized_keys"

if [ "$user" != "root" ]; then
    printf '# Written by %s: lets the GitHub deploy key run update.sh.\n%s ALL=(root) NOPASSWD: %s\n' \
        "$(realpath "$0")" "$user" "$script" > "$tmp/sudoers"
    visudo -cqf "$tmp/sudoers" || die "The sudo rule did not validate."
    install -m 440 -o root -g root "$tmp/sudoers" /etc/sudoers.d/inventory-shipment-deploy
fi

cat <<EOF

$(say "Done. Now save these as secrets on GitHub:")

  github.com/bfa-14/Inventory_Shipment > Settings > Secrets and variables > Actions > New repository secret

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

This key is shown only now and is not kept on the server. Never paste it anywhere but that secret.
Then: Actions tab > "Deploy to server" > Run workflow.
EOF
