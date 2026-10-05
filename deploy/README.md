# Deploying to a Linux server

The whole application runs on one Linux server as three Docker containers:

```
browser ──https──► web  Caddy: the React app, HTTPS certificate (Let's Encrypt), forwards /api
                    │
                    └──/api──► api  Inventory_Shipment.API (ASP.NET Core 10)
                                │
                                └──► db  SQL Server 2025 Express - never reachable from the internet
```

| File | What it is |
|------|------------|
| `docker-compose.yml` | The three containers, their settings and volumes |
| `.env.example` | Every setting, explained. `setup.sh` writes the real one, `.env`, with fresh secrets |
| `setup.sh` | First-time installation |
| `update.sh` | Deploys the latest code: backup, `git pull`, rebuild, restart |
| `backup.sh` / `restore.sh` | Database backup (scheduled nightly) and restore |
| `../Dockerfile` | The API image |
| `Dockerfile`, `Caddyfile` in **Inventory_Shipment_Frontend** | The web image |

## What you need

- **A server** (VPS) with **Ubuntu 24.04** (22.04 and Debian 12 work too) on **x86_64/amd64**. ARM servers
  will not work: SQL Server has no ARM version.
- **At least 2 GB of memory, 4 GB recommended**, 2 CPUs and 30 GB of disk. With less than 4 GB, `setup.sh`
  adds a swap file.
- **SSH access** as root or as a user allowed to use `sudo`: the server's IP address, user name and password (or SSH key).
- **Ports 80 and 443 open.** Some providers (AWS, Azure, Oracle Cloud, Hetzner Cloud firewalls, ...) block them
  until you allow them in their control panel.
- **A domain name** such as `erp.yourcompany.com`, with a DNS **A record** pointing at the server's IP.
  No domain yet? `setup.sh` offers `<ip-with-dashes>.sslip.io` (e.g. `203-0-113-10.sslip.io`), which already
  points at the server and gets a real HTTPS certificate. You can switch to your own domain later.

## Install

1. **Connect to the server** from your computer (Windows: PowerShell or Windows Terminal):

   ```
   ssh root@<server-ip>
   ```

2. **Download the application and run the setup:**

   ```bash
   apt-get update && apt-get install -y git
   mkdir -p /opt/inventory && cd /opt/inventory
   git clone https://github.com/bfa-14/Inventory_Shipment.git
   cd Inventory_Shipment/deploy
   ./setup.sh
   ```

   It asks for the domain and an email address (Let's Encrypt writes there only if a certificate cannot be
   renewed), then installs Docker, downloads the frontend next to this repository, builds everything and starts
   it. The first run takes 5 to 10 minutes. At the end it prints:

   ```
   ==> Inventory & Shipment is running at https://erp.yourcompany.com

       Sign in with:   admin / xxxxxxxxxxxx-Aa1
   ```

3. **Open the address, sign in, and change the admin password** (top-right menu > Change password).
   If it does not open, see [The site does not open](#the-site-does-not-open); meanwhile you can
   [open the app through SSH](#open-the-app-through-ssh).

4. **Set up email** in *Configuration > Settings > Email* (SMTP server, account, password) if you use the approval emails.
   See [Emails are not sent](#emails-are-not-sent) if they fail.

Moving to the server with data you already entered on your PC? Do [Move your existing data](#move-your-existing-data-from-your-pc)
right after step 2.

## Open the app through SSH

If the site does not open from the internet yet (ports 80/443 still blocked by the provider's firewall,
or no certificate yet), you can still use the app through your SSH connection. On your PC:

```
ssh -L 8080:localhost:8080 <user>@<server-ip>
```

Leave that window open and browse to **http://localhost:8080** on the same PC. The traffic travels inside
SSH, so it is encrypted even though the address says `http`. Closing the SSH window closes the tunnel.

The server serves this port on its own `127.0.0.1` only, so nobody can reach it from the internet. Once
80/443 are open, the normal `https://` address works too, with nothing to switch. If 8080 is already taken
on your PC, use another local port: `ssh -L 9090:localhost:8080 ...` and http://localhost:9090.

## Everyday tasks

Run these on the server in `/opt/inventory/Inventory_Shipment/deploy`:

| To | Run |
|----|-----|
| Deploy the latest code from GitHub | `./update.sh` |
| Back up now | `./backup.sh` |
| Restore a backup | `./restore.sh backups/Inventory_Shipment-20261005-023000.bak.gz` |
| See what is running | `docker compose ps` |
| Read the logs | `docker compose logs -f api` (or `web`, `db`), `Ctrl+C` to stop |
| Restart the API | `docker compose restart api` |
| Stop everything / start again | `docker compose down` / `docker compose up -d` |

`update.sh` takes a backup, pulls both repositories, rebuilds and restarts. Database changes need nothing
extra: the API applies `Schema.sql` every time it starts. While the API restarts (under a minute) users see
"The server is not reachable right now".

The containers start again by themselves after a crash or a server reboot.

## Move your existing data from your PC

1. **On your PC, in SSMS:** right-click the `Inventory_Shipment` database > *Tasks* > *Back Up...*, type *Full*,
   destination a file such as `C:\Temp\Inventory_Shipment.bak` > *OK*.
2. **Copy it to the server** from PowerShell on your PC:

   ```
   scp C:\Temp\Inventory_Shipment.bak root@<server-ip>:/root/
   ```

3. **On the server:**

   ```bash
   cd /opt/inventory/Inventory_Shipment/deploy
   ./restore.sh /root/Inventory_Shipment.bak
   ```

   It asks you to type `YES`, replaces the server's database with yours and restarts the API, which brings the
   database up to the current schema.

Afterwards:

- **Sign in with the accounts from your PC.** The users come with the database; the admin password printed by
  `setup.sh` no longer applies.
- **Type the SMTP password again** in *Settings > Email*. It is encrypted with keys that stayed on your PC.
- **Update the site address** in *Settings > Email* if it still points at `localhost`: emailed links use it.

Any SQL Server version up to 2025 can be restored.

## Backups

`backup.sh` runs **every night at 02:30** (server time) and before every `update.sh`. Backups go to
`deploy/backups` and are kept for 14 days (`BACKUP_KEEP_DAYS` in `.env`):

- `Inventory_Shipment-<date>.bak.gz`: the database.
- `keys-<date>.tar.gz`: the keys that decrypt the SMTP password. Without them you only retype that password.

**Copy them off the server regularly.** A server that is lost takes its backups with it. From PowerShell on your PC:

```
scp -r root@<server-ip>:/opt/inventory/Inventory_Shipment/deploy/backups C:\Backups\Inventory
```

The nightly log is `/var/log/inventory-shipment-backup.log`.

## Settings

The settings are in `deploy/.env` (only root can read it). `.env.example` describes each one. To change one,
edit the file (`nano .env`) and run `docker compose up -d`.

- **`DOMAIN`**: point the new name's DNS at the server first. Caddy gets the certificate by itself.
  Then update the site address in *Settings > Email* if one is saved there.
- **`MSSQL_SA_PASSWORD`** is set inside SQL Server on the first start. Changing it in `.env` afterwards only
  locks the API out. To change it, change it in SQL Server first (letters, digits, `-` and `_` only), then in
  `.env`, then run `docker compose up -d`:

  ```bash
  docker compose exec db /opt/mssql-tools18/bin/sqlcmd -C -U sa -P '<current password>' \
      -Q "ALTER LOGIN sa WITH PASSWORD = N'<new password>'"
  ```

- **`JWT_SECRET_KEY`**: changing it signs everybody out. Nothing else is affected.
- **`ADMIN_PASSWORD`** is used only while the database has no users. Changing it later does nothing; change
  the password in the app.

## Security

- Only ports 80 and 443 are open to the internet. SQL Server and the API are reachable only from inside Docker.
- HTTPS everywhere: `http://` redirects to `https://`, with HSTS.
- Each server gets its own secrets in `.env`, which `.gitignore` keeps out of Git. The values in
  `appsettings.Development.json` are public development defaults and are not used on the server.
- The API connects as `sa` because it creates the database on the first start. That is acceptable only
  because SQL Server is not exposed to the internet. Keep it that way: do not publish port 1433.
- Recommended for the server itself: sign in with an SSH key instead of a password, and turn on automatic
  security updates (`apt-get install -y unattended-upgrades`).

## Troubleshooting

### The site does not open

1. `docker compose ps`: all three should be `Up`, `api` and `db` `(healthy)`.
2. `docker compose logs web`: Caddy explains certificate problems here. The usual causes:
   - The domain does not point at this server yet (`getent hosts <domain>` must show the server's IP).
     DNS changes can take up to an hour.
   - Ports 80/443 are blocked by the provider's firewall: from your PC, `curl -sI -m 10 http://<server-ip>`
     prints nothing. Only the provider (or whoever manages the server) can open them; meanwhile use
     [the SSH tunnel](#open-the-app-through-ssh). Once they are open, `docker compose restart web`.
   - Too many failed attempts: Let's Encrypt pauses for an hour. Fix the cause, then wait.

### "The server is not reachable right now"

The page loads but the API does not answer. `docker compose logs --tail 100 api` shows why. While it is
starting (first start, or after `update.sh`) this is normal for up to a few minutes.

### The API restarts over and over

`docker compose logs api` names the setting at fault. Typical causes: a changed `MSSQL_SA_PASSWORD` (see
[Settings](#settings)), or SQL Server stopped for lack of memory (`docker compose logs db`,
`dmesg | grep -i oom`).

### Emails are not sent

Many providers block outgoing mail ports (25, 465, 587) on new servers. Check *Configuration > Settings > Email log* for the
error, and ask the provider to unblock them, or use your mail service's SMTP relay on a port they allow.
