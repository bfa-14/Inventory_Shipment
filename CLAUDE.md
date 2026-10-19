# Inventory & Shipment - notes for Claude

An ERP for inventory, purchasing, logistics (containers) and sales, in two repositories:

- **bfa-14/Inventory_Shipment** (this one): ASP.NET Core 10 API + SQL Server, the database scripts, the deployment.
- **bfa-14/Inventory_Shipment_Frontend**: the React app (Vite, TypeScript, Mantine). Usually checked out next to
  this folder (`../Inventory_Shipment_Frontend`; on the Windows PCs `Inventory_Shipment.Web`).

## Read first

- **The business**: what the company does, the glossary, the modules and their flows, the business rules, the
  numbered prompts done so far and how prompts are written:

  @docs/business-context.md

- Item costing rules: `docs/notes/costing-rules.md`. Original plan: `docs/plans/inventory-module-plan.md`.
  Earlier prompts as they were given: `docs/prompts/`. Excel import samples: `docs/samples/`.
- UI rules (grids, filters, modals, document pages, numbers): `docs/frontend-conventions.md` in the frontend.
- Deployment and server operations: `deploy/README.md`.

## Layout

```
Inventory_Shipment.API          controllers, auth (JWT + permission policies), workers (email outbox, approval reminders)
Inventory_Shipment.Service      business logic, Excel import (ClosedXML), email (MailKit), seeding
Inventory_Shipment.Repository   Dapper over stored procedures; Database/Schema.sql (embedded, applied at start-up)
Inventory_Shipment.Model        DTOs, entities, enums, options - no dependencies
Database/NN_*.sql               one idempotent script per change, numbered in order
DatabaseProject/                SSDT project mirroring the database (refreshed by tools/refresh-dbproject.sh)
tools/                          refresh-dbproject.sh, compare-dbproject.sh, sync-sqlproj.py
deploy/                         Docker stack and server scripts (setup, update, backup, restore)
```

## How a change is made (one numbered prompt)

1. **Database**: a new `Database/NN_Module_Title.sql` with the next free number, idempotent (`IF COL_LENGTH ... IS NULL`,
   `CREATE OR ALTER`, ...). Append the same script to `Inventory_Shipment.Repository/Database/Schema.sql` under
   `-- ===== NN: Title =====`. Schema.sql runs on **every** API start and must also work on a **brand-new, empty
   database** (that is what the server got): create a table or column before any procedure that reads it, because
   `CREATE OR ALTER PROCEDURE` fails on a missing column. Then refresh `DatabaseProject` with `tools/refresh-dbproject.sh`.
2. **Back end**: Model (DTOs) -> Repository (Dapper call to the procedure) -> Service (rules, validation) -> API
   controller guarded by a permission (`[HasPermission(Permissions.Purchase....)]`; new codes go in
   `Inventory_Shipment.Model/Security/PermissionCatalog.cs`). Business errors are `THROW` with a number from the
   module's block in `Inventory_Shipment.Repository/Database/SqlErrors.cs`, turned into ProblemDetails with a
   `code` the pages read.
3. **Front end**: typed client in `src/api/`, pages in `src/pages/`, shared pieces in `src/components/`, and a section
   in `docs/frontend-conventions.md` for any new pattern.
4. Commit message: what changed, ending with `(prompt NN)`.

Conventions worth keeping:

- `*Utc` columns hold UTC and go out as ISO with `Z`; calendar dates (DocumentDate, Eta, ...) are plain dates.
- Costs per **base unit** in the **base currency**; documents keep their own currency and rate.
- Comments explain *why*, often opening with an upper-case summary sentence. Match the style of the file you edit.

## Checks before pushing

- Back end: `dotnet build Inventory_Shipment.API` (there is no test project).
- Front end: `npm run lint`, `npm run typecheck`, `npm run build`.
- Database changes: apply `Schema.sql` to an **empty** database as well as to an existing one.

## Environments and branches

- One Ubuntu server runs two environments with Docker, each with its own web app, API and SQL Server database
  (`deploy/README.md`):
  - **production**: `https://188-245-17-182.sslip.io`, the `production` branch, `/opt/inventory`
  - **testing**: `https://test.188-245-17-182.sslip.io`, the `main` branch, `/opt/inventory-test`
- A proxy (Caddy, `deploy/proxy/Caddyfile`) serves both addresses with HTTPS. The sign-in page's "Test
  environment" switch moves between them; testing shows a TESTING badge and never emails real people.
- New work goes to `main` (what testing runs); a tested version is merged into `production` (what production
  runs), in both repositories. Never commit straight to `production`.
- Deploy: only by hand. The "Deploy to server" button (GitHub Actions, run from GitHub, VS Code or Visual Studio,
  once set up; production also asks to type "production"), or on the server `sudo ./update.sh` in that
  environment's `deploy/` folder. A push deploys nothing (`deploy/README.md`, "Deploying with a button"). Each API
  applies Schema.sql as it starts.
- Both repositories live on GitHub (`bfa-14/Inventory_Shipment`, `bfa-14/Inventory_Shipment_Frontend`): the team
  pushes and merges there, and the server pulls from there (`deploy/README.md`, "The repositories: GitHub").
- Never commit `deploy/.env`, and never ask for or repeat passwords, keys or server credentials.

## Working with the user

- Short, plain English. For anything they run, say **where**: on their PC, on the server, or in the browser.
- When asked for business prompts, follow "How we write prompts" in `docs/business-context.md`, continue the
  numbering from its prompt list, and check the code for what already exists before proposing a change.
