# Deploying to a Linux server

The application runs on one Linux server in **two environments**, each with its own web app, API and SQL
Server database:

| Environment | Address | Code | On the server |
|-------------|---------|------|---------------|
| **Production** | `https://<domain>` | the `production` branch | `/opt/inventory` |
| **Testing** | `https://test.<domain>` | the `main` branch | `/opt/inventory-test` |

```
                      ┌─ <domain> ───────► production:  web ─┐ api ──► db   (production branch)
browser ──https──► proxy                                     (/api goes straight to the api)
   (ports 80/443)     └─ test.<domain> ──► testing:     web ─┘ api ──► db   (main branch)
```

- **proxy**: Caddy, the only container the internet reaches. It gets the HTTPS certificates for both
  addresses and sends each one to its environment. Production runs it.
- **web**: the React app, from the Inventory_Shipment_Frontend repository.
- **api**: Inventory_Shipment.API (ASP.NET Core 10). It applies `Schema.sql` to its own database at start-up.
- **db**: SQL Server 2025 Express. It is never reachable from the internet.

The **sign-in page has a "Test environment" switch** that moves between the two addresses. In testing, every
page shows an orange **TESTING** badge, and **emails are never sent to real people**.

| File | What it is |
|------|------------|
| `docker-compose.yml` | One environment's containers (and production's proxy), settings and volumes |
| `proxy/Caddyfile` | The proxy: HTTPS for both addresses, which goes where |
| `.env.example` | Every setting, explained. `setup.sh` writes the real ones (`.env`, one per environment) with fresh secrets |
| `setup.sh` | First-time installation; `setup.sh testing` adds the testing environment |
| `update.sh` | Deploys the latest code of an environment: backup, `git pull`, rebuild, restart |
| `copy-production-to-testing.sh` | Refreshes testing's database with a copy of production's |
| `enable-github-deploy.sh` | One-time setup so a push to `main` or `production` deploys by itself (`../.github/workflows/deploy.yml`) |
| `backup.sh` / `restore.sh` | Database backup (scheduled nightly) and restore |
| `reset-database.sh` | Empties an environment's database, keeping only your admin account |
| `../Dockerfile` | The API image |
| `Dockerfile`, `Caddyfile` in **Inventory_Shipment_Frontend** | The web image |

## What you need

- **A server** (VPS) with **Ubuntu 24.04** (22.04 and Debian 12 work too) on **x86_64/amd64**. ARM servers
  will not work: SQL Server has no ARM version.
- **At least 2 GB of memory, 4 GB recommended**, 2 CPUs and 30 GB of disk. With less than 4 GB, `setup.sh`
  adds a swap file. With the testing environment (a second SQL Server), **6 GB or more**: `setup.sh testing`
  stops below that unless you accept the risk (`sudo ALLOW_LOW_MEMORY=yes ./setup.sh testing`).
- **SSH access** as root or as a user allowed to use `sudo`: the server's IP address, user name and password (or SSH key).
- **Ports 80 and 443 open.** Some providers (AWS, Azure, Oracle Cloud, Hetzner Cloud firewalls, ...) block them
  until you allow them in their control panel.
- **A domain name** such as `erp.yourcompany.com`, with a DNS **A record** pointing at the server's IP, and one
  for `test.erp.yourcompany.com` (the testing environment).
  No domain yet? `setup.sh` offers `<ip-with-dashes>.sslip.io` (e.g. `203-0-113-10.sslip.io`). It already
  points at the server, `test.` in front of it too, and gets real HTTPS certificates. You can switch to your
  own domain later.

## Install

1. **Connect to the server** from your computer (Windows: PowerShell or Windows Terminal):

   ```
   ssh root@<server-ip>
   ```

   Signed in as another user? Run `sudo -i` first: the commands below run as root.

2. **Download the application and run the setup:**

   ```bash
   apt-get update && apt-get install -y git
   mkdir -p /opt/inventory && cd /opt/inventory
   git clone --branch production https://github.com/bfa-14/Inventory_Shipment.git
   cd Inventory_Shipment/deploy
   ./setup.sh
   ```

   `--branch production`: production runs the tested `production` branch, never `main` (setup.sh refuses
   another branch once `production` exists, and downloads the frontend on the same branch).

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
right after step 2. Then add the testing environment: [Two environments](#two-environments-production-and-testing).

## Open the app through SSH

If a site does not open from the internet (ports 80/443 blocked by the provider's firewall, or no
certificate yet), you can still use it through your SSH connection. On your PC:

```
ssh -L 8080:localhost:8080 -L 8081:localhost:8081 <user>@<server-ip>
```

Leave that window open and browse on the same PC to **http://localhost:8080** (production) or
**http://localhost:8081** (testing). The traffic travels inside SSH, so it is encrypted even though the address
says `http`. Closing the SSH window closes the tunnel.

The server serves these ports on its own `127.0.0.1` only, so nobody can reach them from the internet. If a
port is already taken on your PC, use another local one: `-L 9090:localhost:8080` and http://localhost:9090.

## Two environments: production and testing

Production is what the company uses. Testing is where new work is tried first, on a copy of production's data,
without risk.

### Add the testing environment (once)

**On a server installed before the two environments** (it served the site from its web container), upgrade
production first, in the production folder: `sudo ./update.sh production`. It must end with
"Updated production" (see [Upgrade a server installed before the two environments](#upgrade-a-server-installed-before-the-two-environments)).

Then, on the server, in the **production** folder:

```bash
cd /opt/inventory/Inventory_Shipment/deploy
sudo ./setup.sh testing
```

It does everything in one go:

1. Checks out both repositories on `main` into `/opt/inventory-test`.
2. Writes testing's `.env`, with its own secrets and its own database.
3. Builds and starts testing.
4. Turns on the switch on production's sign-in page.
5. Offers to copy production's database into testing. Run again later, it keeps testing's data unless you
   answer `yes` (and then type `YES`).

Testing's address is `TEST_DOMAIN` in production's `.env`, by default `test.<domain>`. With sslip.io that
already works. With your own domain, first add a DNS A record for `test.<your domain>` pointing at the server.

### Testing's data

Testing has its **own database**, so nothing done there touches production. To refresh it with a copy of
production's, whenever you want:

```bash
cd /opt/inventory-test/Inventory_Shipment/deploy
sudo ./copy-production-to-testing.sh
```

- **Users and passwords** come along: sign in to testing with your production account. Everyone signs in
  again (production's sign-ins are not copied).
- **A user disabled, or a password changed, in production afterwards still works in testing** until the next
  copy. Disable or change it in testing too, or copy again.
- **The schema:** testing's API brings the copy up to `main`'s schema as it starts. That is a rehearsal of the
  next production update: if it fails there, it would have failed in production.

Testing holds production's data at a public address. To keep it to the company's network, list the allowed
addresses in **production's** `.env` (`TEST_ALLOWED_IPS=203.0.113.10 198.51.100.0/24`, separated by spaces),
then `sudo docker compose up -d` in production's folder. Everyone else gets a "403" page. Leave it empty while
the office addresses change often: a wrong list locks everybody out of testing (not out of production).

### Emails in testing

Testing's data contains real suppliers' and approvers' addresses, so **testing never emails them**. Emails
stay *Pending* in its Email log.

To see them anyway:
1. Set `TEST_EMAIL_REDIRECT_TO=you@yourmail.com` in `/opt/inventory-test/Inventory_Shipment/deploy/.env`
   (`sudo nano .env` in that folder).
2. Run `sudo docker compose up -d` in that folder.
3. Type the SMTP password again in testing's *Configuration > Settings > Email*.

Every email then goes to that one address only, with the subject starting with `[TEST]`.

## Branches and deploying

| Branch | Environment | Who pushes |
|--------|-------------|------------|
| `main` | **testing** | everyone, all new work |
| `production` | **production** | only when a version is tested and approved |

The everyday cycle:

1. **Work** is pushed to `main`, and **testing** is updated with it (automatically, or `sudo ./update.sh` in
   `/opt/inventory-test/Inventory_Shipment/deploy`).
2. **Test** it on `https://test.<domain>`.
3. **Release**: merge `main` into `production`, in **both** repositories, and push. **Production** is updated
   with it (automatically, or `sudo ./update.sh` in `/opt/inventory/Inventory_Shipment/deploy`).

   On GitHub: **Pull requests > New pull request**, base `production`, compare `main`, then **Merge pull
   request** (keep "Create a merge commit"), in both repositories. Or on your PC, in **both** repositories
   (`Inventory_Shipment` and `Inventory_Shipment.Web`):

   ```bash
   git fetch origin && (git checkout production 2>/dev/null || git checkout -b production --track origin/production) && git pull --ff-only origin production && git merge --no-edit origin/main && git push origin production && git checkout main
   ```

   It releases `origin/main`, exactly what testing runs, not your own `main` (which may hold work not pushed
   or not tested yet).

Each environment's `update.sh` takes a backup, pulls **both** repositories on its branch, rebuilds and restarts.
Database changes need nothing extra: each API applies `Schema.sql` to its own database as it starts.

**Never commit straight to `production`.** A fix goes to `main` first, is checked in testing, then is merged.

### The repositories: GitHub

Both repositories live on GitHub, private, under the `bfa-14` account: **`bfa-14/Inventory_Shipment`** (API,
database, deployment) and **`bfa-14/Inventory_Shipment_Frontend`** (web). Everyone pushes and merges there, and
the server pulls from there.

In every clone, `origin` is GitHub:

```bash
git remote -v
```

shows `https://github.com/bfa-14/Inventory_Shipment` in the API folder and
`https://github.com/bfa-14/Inventory_Shipment_Frontend` in the web folder. A clone that points anywhere else is
switched with `git remote set-url origin <the address above>`, then `git fetch origin && git branch -u origin/main
main`. Someone joining the team needs to be added on GitHub (**Settings > Collaborators** in each repository)
before they can clone or push.

### Deploying automatically from GitHub (one-time setup)

A push to `main` or `production`, in either repository, then deploys the matching environment by itself. You
can also deploy by hand: **Actions > Deploy to server > Run workflow**, choosing the environment.

1. **On the server**, in the production folder, after `setup.sh testing`:

   ```bash
   cd /opt/inventory/Inventory_Shipment/deploy
   sudo ./enable-github-deploy.sh
   ```

   It installs `inventory-deploy` (`production` or `testing`: runs that environment's `update.sh`). It creates an
   SSH key that can run only that command. It prints a table of values and the key.
2. **On GitHub**, in **both** repositories: **Settings > Secrets and variables > Actions > New repository
   secret**, once per line of the table:
   - `DEPLOY_HOST`
   - `DEPLOY_USER`
   - `DEPLOY_KNOWN_HOSTS`
   - `DEPLOY_PORT`, only if it is listed
   - `DEPLOY_SSH_KEY`: the whole key, `BEGIN` and `END` lines included.
3. **Try it:** Actions > Deploy to server > Run workflow > testing.

Until the secrets are there, pushes skip the deployment (with a note in the Actions log). The key is shown only
once: run the script again to make a new one (the old one stops working).

Each deployment is also written to `/var/log/inventory-deploy-production.log` (or `-testing.log`) on the
server. A deployment runs to its end even if its GitHub job is cancelled or times out: cancelling only stops
showing its progress on GitHub.

From your PC, the same command, by hand:

```
ssh -t <user>@<server-ip> sudo inventory-deploy testing      (or production)
```

### Which branch an environment runs

Each environment deploys the branch its checkouts are on: `production` in `/opt/inventory`, `main` in
`/opt/inventory-test`. `update.sh` refuses to deploy when the two checkouts (API and frontend) are on different
branches, or when production is not on `production`. To move an environment to another branch, once (both
checkouts move together):

```bash
sudo ./update.sh production
```

### Upgrade a server installed before the two environments

Such a server runs production from `main`, with the HTTPS certificate in its web container. Once the
`production` branch exists on GitHub in both repositories, on the server:

```bash
sudo ufw status
cd /opt/inventory/Inventory_Shipment/deploy
sudo ./update.sh production
```

- `ufw status`: if it says `Status: active`, `update.sh` opens ports 80 and 443 in it (the proxy needs them;
  the old web container went around ufw).
- `update.sh production` backs up the database, moves both checkouts to `production`, and starts the proxy in
  place of the web container's HTTPS. The data, and the certificate, are kept. It must end with
  "Updated production"; then add testing: [Add the testing environment](#add-the-testing-environment-once).

## Goods receipts go-live (once)

From database scripts 64 and 65 on, **goods enter the stock only through a goods receipt** (Purchase > Goods
Receipts). A supplier invoice posted after that moves no stock: it makes the amount payable and corrects the cost of
goods already received. Each API applies the scripts as it starts, and its first start writes the **switch date**
(`purchase.GoodsReceiptSwitch`, one row per database). Documents posted before it keep their stock and cost; such an
invoice says "Posted before goods receipts".

**The switch is one-way.** Once a goods receipt, or an invoice posted the new way, exists, the older code would
receive the same goods twice. The only way back is `sudo ./restore.sh` with the backup `update.sh` took just before it
pulled, and everything entered after that backup is lost.

1. **Rehearse on testing first.** On the server, in testing's folder:

   ```bash
   cd /opt/inventory-test/Inventory_Shipment/deploy
   sudo ./copy-production-to-testing.sh
   ```

   - Run [the check](#what-the-switch-will-do-read-only) there and keep what it prints.
   - Merge the goods receipts work into `main`, in both repositories, **Web first, then API**: the deploy that the API
     push starts then finds the new web.
   - When testing has updated: `sudo docker compose logs api | grep "Database schema verified"`.
   - In the app, find what the check announced: Logistics > Containers, Status "Delivered, not received";
     Purchase > Purchase Invoices, "Not fully received"; Purchase > Purchase Orders, "To receive".
   - On the copy, take one local purchase (order, Receive goods…, post, then the invoice) and one container (complete
     its Delivery movement, post the draft goods receipt) to the end. Try an invoice cancel, a return and a short
     shipment too.
2. **Production**, at a quiet moment, once the rehearsal's lists are reviewed. In production's folder:
   - Check that last night's backup is there: `sudo ls -lt backups | head -3`. `update.sh` takes one more before it
     pulls.
   - Run the check and keep what it prints. It changes nothing.
   - Merge `main` into `production`, **Web first, then API** ([Branches and deploying](#branches-and-deploying)).
   - Afterwards: "Database schema verified" in the API log, and an old supplier invoice says "Posted before goods
     receipts".
   - Tell the warehouse, logistics and accounting. Containers are received with **Receive goods…** (a draft is made
     when their Delivery movement is completed). Local purchases are received with **Receive goods…** on the order or
     the invoice, or with "Receive the goods now" when the invoice is posted.
3. **Every other database** switches at its API's next start after a pull (a developer PC, for example): save your
   work first.

### What the switch will do (read-only)

Run it **before** the update. It reads only tables that exist before goods receipts, and changes nothing. The SA
password stays inside the database container: never type it, never put it in the command. Paste the whole block, in
the environment's deploy folder. If `.env` sets `DB_NAME`, put that name in place of `Inventory_Shipment`.

```bash
sudo docker compose exec -T db bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -C -I -b -S localhost -U sa -d Inventory_Shipment -W -s "|"' <<'SQL'
SET NOCOUNT ON;
-- Order lines of approved orders (open or closed), counted the way the switch counts them: received = the stock of
-- local invoices + containers offloaded; short = what those offloads recorded short.
SELECT d.DocumentNumber, OrderStatus = CASE d.Status WHEN 2 THEN N'Open' ELSE N'Closed' END, d.CloseReason,
       pol.LineNumber, i.ItemCode, OrderedPcs = pol.QuantityBase, InvoicedPcs = pol.ReceivedQuantityBase,
       ReceivedPcs = ISNULL(inv.Qty, 0) + ISNULL(olo.Qty, 0), ShortPcs = ISNULL(olo.Short, 0),
       InContainersPcs = ISNULL(way.Qty, 0),
       StillToReceivePcs = CASE WHEN d.Status = 4 THEN pol.ReceivedQuantityBase ELSE pol.QuantityBase END
                           - ISNULL(inv.Qty, 0) - ISNULL(olo.Qty, 0) - ISNULL(olo.Short, 0)
INTO #Lines
FROM purchase.PurchaseDocumentLines pol
INNER JOIN purchase.PurchaseDocuments d ON d.Id = pol.DocumentId AND d.Status IN (2, 4)
INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
INNER JOIN inventory.Items i            ON i.Id = pol.ItemId
OUTER APPLY (SELECT Qty = SUM(m.QuantityBase)
             FROM inventory.StockMovements m
             INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.DocumentLineId AND il.DocumentId = m.DocumentId
             WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'PINV' AND m.IsReversal = 0
               AND il.SourceLineId = pol.Id
               AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r
                               WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                 AND r.DocumentId = m.DocumentId AND r.IsReversal = 1)) inv
OUTER APPLY (SELECT Qty   = SUM(ISNULL(cl.ReceivedQuantityBase, 0)),
                    Short = SUM(CASE WHEN cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase)
                                     THEN cl.QuantityBase - cl.ReceivedQuantityBase ELSE 0 END)
             FROM logistics.ContainerLines cl
             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId AND c.Status IN (6, 7)
             WHERE cl.PoLineId = pol.Id) olo
OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase)
             FROM logistics.ContainerLines cl
             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId AND c.Status BETWEEN 1 AND 5
             WHERE cl.PoLineId = pol.Id) way;

-- Containers confirmed to cleared whose latest Delivery-stage movement is completed.
SELECT c.ContainerRef, c.ContainerNo, c.Status, ld.MovementNo, ld.EndDate, DeliveredTo = ld.PortName
INTO #Delivered
FROM logistics.Containers c
CROSS APPLY (SELECT TOP (1) m.MovementNo, m.EndDate, p.PortName
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId AND m.Status = 3
             INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId AND mt.Stage = N'Delivery'
             INNER JOIN masterdata.Ports p          ON p.Id = m.ToPlaceId
             WHERE mc.ContainerId = c.Id
             ORDER BY m.EndDate DESC, m.Id DESC) ld
WHERE c.Status BETWEEN 2 AND 5;

-- Lines of posted "Shipped in containers" invoices in no container and not received.
SELECT d.DocumentNumber, l.LineNumber, i.ItemCode, InvoicedPcs = l.QuantityBase, ReceivedPcs = l.ReceivedQuantityBase
INTO #Unlinked
FROM purchase.PurchaseDocumentLines l
INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId AND d.Status IN (2, 4) AND d.ReceiptMode = 2
INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
INNER JOIN inventory.Items i            ON i.Id = l.ItemId
WHERE l.ContainerLineId IS NULL AND l.ReceivedQuantityBase < l.QuantityBase;

PRINT '1. What the switch finds';
SELECT Situation, Number FROM (VALUES
    (1, N'Containers on the way (Confirmed to Cleared): received with goods receipts',
        (SELECT COUNT(*) FROM logistics.Containers WHERE Status BETWEEN 2 AND 5)),
    (2, N'- of which the Delivery is already completed: no automatic draft (list 2)', (SELECT COUNT(*) FROM #Delivered)),
    (3, N'Draft supplier invoices: they move no stock when they are posted',
        (SELECT COUNT(*) FROM purchase.PurchaseDocuments d
         INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV' WHERE d.Status = 1)),
    (4, N'Posted "Shipped in containers" invoice lines in no container, not received (list 3)',
        (SELECT COUNT(*) FROM #Unlinked)),
    (5, N'Order lines with goods still to receive (list 4)', (SELECT COUNT(*) FROM #Lines WHERE StillToReceivePcs > 0))
) s (Sort, Situation, Number)
ORDER BY Sort;
PRINT '2. Delivered, not received: Receive goods... on each container after the switch';
SELECT * FROM #Delivered ORDER BY EndDate, ContainerRef;
PRINT '3. Matched to their container''s goods when it is received, else Receive goods... on the invoice';
SELECT * FROM #Unlinked ORDER BY DocumentNumber, LineNumber;
PRINT '4. Order lines still to receive after the switch';
SELECT * FROM #Lines WHERE StillToReceivePcs > 0 ORDER BY DocumentNumber, LineNumber;
GO
SQL
```

What it prints:

1. **The counts** of each situation below, plus the draft supplier invoices (they follow the new rule when they are
   posted).
2. **Containers delivered but not received.** A Delivery completed before the switch made no draft goods receipt: use
   Receive goods… on each of them.
3. **Lines of posted "Shipped in containers" invoices in no container.** They are matched to their container's goods
   when it is received; goods that came without a container are received with Receive goods… on the invoice.
4. **Order lines still to receive.** Received is what the switch counts (the stock of old local invoices and of
   offloaded containers), Short is what old offloads recorded short, and Still to receive is what the app then shows
   as still to come (Shortages, the item's "On order", Receive goods…). A closed order counts what was invoiced, not
   ordered: an order closed "Fully received" with goods still in containers stays closed, and its goods can still be
   received.

After the update, use the app's lists instead: this check does not count goods receipts.

## Everyday tasks

Run these on the server, in the deploy folder of the environment concerned. Signed in as root, leave out `sudo`.

- **Production:** `/opt/inventory/Inventory_Shipment/deploy`
- **Testing:** `/opt/inventory-test/Inventory_Shipment/deploy`

| To | Run |
|----|-----|
| Deploy the latest code from GitHub | `sudo ./update.sh` (or automatically: [Branches and deploying](#branches-and-deploying)) |
| Back up now | `sudo ./backup.sh` |
| Restore a backup | `sudo ./restore.sh backups/Inventory_Shipment-20261005-023000.bak.gz` |
| Refresh testing with production's data | `sudo ./copy-production-to-testing.sh` (testing folder) |
| Empty an environment's database (keeps only your admin account) | `sudo ./reset-database.sh` ([details](#empty-a-database-start-again-from-zero)) |
| See what is running | `sudo docker compose ps` |
| Read the logs | `sudo docker compose logs -f api` (or `web`, `db`, and `proxy` in production), `Ctrl+C` to stop |
| Restart the API | `sudo docker compose restart api` |
| Stop everything / start again | `sudo docker compose down` / `sudo docker compose up -d` |

Stopping production also stops the proxy, so testing's address stops answering too.

While an API restarts (under a minute) its users see "The server is not reachable right now". The containers
start again by themselves after a crash or a server reboot.

## Empty a database (start again from zero)

To go live without the test data, empty production, then copy it into testing (the `&&` runs the copy only if the
reset finished):

```bash
cd /opt/inventory/Inventory_Shipment/deploy
sudo ./reset-database.sh && sudo /opt/inventory-test/Inventory_Shipment/deploy/copy-production-to-testing.sh
```

`reset-database.sh` asks you to type the environment's address, takes a backup, and leaves the database exactly as a
new installation creates it, **except that your admin account stays, with its current password**:

- **Deleted:** every document (orders, invoices, goods receipts, returns, sales, receipts), stock and costs,
  containers and movements, items, suppliers and customers, other users, settings (email, approval), the email log,
  attached files. Document numbers start again at 1. **Everyone is signed out**, you too: sign in again.
- **Created again, as on a new installation** (they would come back at every start if deleted: change, deactivate
  or delete them in the app instead):
  - the document types, the permissions and the default settings;
  - the roles Admin, Manager, User and Owner (nobody holds them but your account, which is Admin);
  - the starter rows: branch BR-001 Head Office and its warehouse, currencies, ports, item families, unit,
    container, movement and charge types, attachment types, stock reasons, payment methods, the TVS brand,
    supplier SUP-0001 TVS Motor Company, customer CLI-0001 Walk-in Customer, the demo item TVS-AP160 and price list
    PL-001 Retail USD with its price.
- Another administrator account to keep: `sudo KEEP_USER=<user name> ./reset-database.sh`.
- Stopped halfway (a lost connection)? Run it again: it carries on. The copy into testing refuses to run until it
  has finished.
- **The backup** it takes is kept in `deploy/backups/before-reset/` (the nightly clean-up does not touch it). To
  undo the reset: `sudo ./restore.sh backups/before-reset/<the file it printed>`; restoring it after going live
  replaces everything entered since. Copy it off the server ([Backups](#backups)) before you ever delete it.

## Move your existing data from your PC

1. **On your PC, in SSMS:** right-click the `Inventory_Shipment` database > *Tasks* > *Back Up...*, type *Full*,
   destination a file such as `C:\Temp\Inventory_Shipment.bak` > *OK*.
2. **Copy it to the server** from PowerShell on your PC:

   ```
   scp C:\Temp\Inventory_Shipment.bak <user>@<server-ip>:
   ```

3. **On the server** (as `<user>`; `~` is that user's home folder):

   ```bash
   cd /opt/inventory/Inventory_Shipment/deploy
   sudo ./restore.sh ~/Inventory_Shipment.bak
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

`backup.sh` runs **every night** (server time) and before every `update.sh`, in each environment, into its own
`deploy/backups`. Kept for 14 days (`BACKUP_KEEP_DAYS` in `.env`):

| Environment | When | Backups | Log |
|-------------|------|---------|-----|
| Production | 02:30 | `/opt/inventory/Inventory_Shipment/deploy/backups` | `/var/log/inventory-shipment-backup.log` |
| Testing | 02:45 | `/opt/inventory-test/Inventory_Shipment/deploy/backups` | `/var/log/inventory-shipment-backup-testing.log` |

Each backup is two files:

- `Inventory_Shipment-<date>.bak.gz`: the database.
- `keys-<date>.tar.gz`: the keys that decrypt the SMTP password. Without them you only retype that password.

**Copy production's off the server regularly.** A server that is lost takes its backups with it. From
PowerShell on your PC (only root can read the folder, so it is packed first):

```
ssh <user>@<server-ip> 'sudo tar -C /opt/inventory/Inventory_Shipment/deploy -czf inventory-backups.tgz backups && sudo chown $USER inventory-backups.tgz'
scp <user>@<server-ip>:inventory-backups.tgz C:\Backups\Inventory\
ssh <user>@<server-ip> rm inventory-backups.tgz
```

## Settings

The settings are in `deploy/.env`, one per environment (only root can read it). `.env.example` describes each
one. To change one, edit the file (`sudo nano .env`) and run `sudo docker compose up -d` in the same folder.

- **Your own domain instead of sslip.io** (or any change of address): both environments know both addresses.
  1. Add DNS A records for `<new>` and `test.<new>` pointing at the server.
  2. Production's `.env`: `DOMAIN=<new>`, `TEST_DOMAIN=test.<new>`, `SWITCH_URL=https://test.<new>`.
  3. Testing's `.env`: `DOMAIN=test.<new>`, `TEST_DOMAIN=test.<new>`, `SWITCH_URL=https://<new>`.
  4. `sudo docker compose up -d` in testing's folder, then in production's. The proxy gets the certificates.
  5. Update the site address in *Settings > Email* in both environments, if one is saved there.
- **`MSSQL_SA_PASSWORD`** is set inside SQL Server on the first start. Changing it in `.env` afterwards only
  locks the API out. To change it, change it in SQL Server first (letters, digits, `-` and `_` only), then in
  `.env`, then run `sudo docker compose up -d`:

  ```bash
  sudo docker compose exec db /opt/mssql-tools18/bin/sqlcmd -C -U sa -P '<current password>' \
      -Q "ALTER LOGIN sa WITH PASSWORD = N'<new password>'"
  ```

- **`JWT_SECRET_KEY`**: changing it signs everybody out. Nothing else is affected.
- **`ADMIN_PASSWORD`** is used only while the database has no users. Changing it later does nothing; change
  the password in the app.

## Security

- Only ports 80 and 443 (the proxy) are open to the internet. Each environment's API and web app listen on the
  server's `127.0.0.1` only. SQL Server is reachable only from inside its environment's Docker network.
- The two environments share nothing but the proxy: separate containers, databases, volumes, secrets and
  images (`inventory-*` and `inventory-test-*`).
- HTTPS everywhere: `http://` redirects to `https://`, with HSTS.
- Each server gets its own secrets in `.env`, which `.gitignore` keeps out of Git. The values in
  `appsettings.Development.json` are public development defaults and are not used on the server.
- The API connects as `sa` because it creates the database on the first start. That is acceptable only
  because SQL Server is not exposed to the internet. Keep it that way: do not publish port 1433.
- Recommended for the server itself: sign in with an SSH key instead of a password, and turn on automatic
  security updates (`apt-get install -y unattended-upgrades`).
- The GitHub deploy key can only start `inventory-deploy production|testing` (a forced command with `restrict`
  in `authorized_keys`); it cannot open a shell or reach anything else. `update.sh` runs the code it pulls, so
  whoever can push to `main` or `production` decides what the server runs: keep that list short.
- **Protect `production` on GitHub**, in both repositories: **Settings > Branches > Add branch protection rule**
  (or **Rules > Rulesets**), branch `production`: *Require a pull request before merging*, and *Restrict who can
  push* to the people who release. Releases then go through a pull request (see
  [Branches and deploying](#branches-and-deploying)); the deploy workflow only reads the repositories, so the rule
  does not stop it.
- Testing holds a copy of production's data: see [Testing's data](#testings-data) to keep it to the company's
  network. The GitHub repositories should be **private**.
- When memory runs out, the kernel stops testing's processes before production's (`OOM_SCORE_ADJ=500` in
  testing's `.env`).

## Troubleshooting

### The site does not open

1. `sudo docker compose ps` in production's deploy folder: `proxy`, `web`, `api` and `db` should be `Up`, `api`
   and `db` `(healthy)`. For testing's address, also in testing's folder (no `proxy` there).
2. `sudo docker compose logs proxy` (production's folder): Caddy explains certificate problems here, for both
   addresses. The usual causes:
   - The domain does not point at this server yet (`getent hosts <domain>` must show the server's IP).
     DNS changes can take up to an hour.
   - Ports 80/443 are blocked by the provider's firewall: from your PC, `curl -sI -m 10 http://<server-ip>`
     prints nothing. Only the provider (or whoever manages the server) can open them; meanwhile use
     [the SSH tunnel](#open-the-app-through-ssh). Once they are open, `sudo docker compose restart proxy`.
   - `sudo ufw status` says `Status: active` without `80/tcp` and `443/tcp` ALLOW: run
     `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw allow 443/udp` (`update.sh` does it too).
   - Testing's address answers "403": `TEST_ALLOWED_IPS` in production's `.env` does not list your address.
   - Only testing's address fails: with your own domain, `test.<domain>` needs its own DNS A record.
   - Too many failed attempts: Let's Encrypt pauses for an hour. Fix the cause, then wait.

### "The server is not reachable right now"

The page loads but the API does not answer. `sudo docker compose logs --tail 100 api` shows why. While it is
starting (first start, or after `update.sh`) this is normal for up to a few minutes.

### The API restarts over and over

`sudo docker compose logs api` names the setting at fault. Typical causes: a changed `MSSQL_SA_PASSWORD` (see
[Settings](#settings)), or SQL Server stopped for lack of memory (`sudo docker compose logs db`,
`sudo dmesg | grep -i oom`).

### Emails are not sent

Many providers block outgoing mail ports (25, 465, 587) on new servers. Check *Configuration > Settings > Email log* for the
error, and ask the provider to unblock them, or use your mail service's SMTP relay on a port they allow.
