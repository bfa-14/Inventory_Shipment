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
tools/                          refresh-dbproject.sh, compare-dbproject.sh, sync-sqlproj.py, sort-dbproject-tables.py
deploy/                         Docker stack and server scripts (setup, update, backup, restore)
```

## How a change is made (one numbered prompt)

1. **Database**: a new `Database/NN_Module_Title.sql` with the next free number, idempotent (`IF COL_LENGTH ... IS NULL`,
   `CREATE OR ALTER`, ...). Append the same script to `Inventory_Shipment.Repository/Database/Schema.sql` under
   `-- ===== NN: Title =====`. Schema.sql runs on **every** API start and must also work on a **brand-new, empty
   database** (that is what the server got): create a table or column before any procedure that reads it, because
   `CREATE OR ALTER PROCEDURE` fails on a missing column.
   - **Re-create from the LAST body.** A procedure or function is re-created with `CREATE OR ALTER` from its current
     definition - the last one in `Schema.sql` - plus the change. Starting from an older body silently undoes every fix
     a later script made to it (the review of every script checks this first).
   - `Database/NN_*.sql` and its `Schema.sql` section are byte-identical; the section ends with `SET NOEXEC OFF;` `GO`.
   - A data step that must run once per database records itself in `inventory.OneTimeSteps` (script 89); a permission
     is granted once when it is created, to the roles named in the script, and never re-granted (scripts 64, 75, 90-94).
   - Every INSERT into `inventory.StockMovements` stamps `CreatedBy` with the acting user and never uses OUTPUT without
     INTO (the warehouse access trigger of script 92 reads it; OUTPUT without INTO fails on a table with a trigger).
   - `DatabaseProject` is refreshed only from a clean database built by the API of the commit being pushed (the way the
     servers get it): `tools/refresh-dbproject.sh` on that database, committed as "DatabaseProject refreshed (up to
     script NN)". Developer PCs only pull it; `tools/compare-dbproject.sh --diff` (read-only, `DB=` a connection string
     or the sqlcmd variables) shows how any database differs from it.
2. **Back end**: Model (DTOs) -> Repository (Dapper call to the procedure) -> Service (rules, validation) -> API
   controller guarded by a permission (`[HasPermission(Permissions.Purchase....)]`; new codes go in
   `Inventory_Shipment.Model/Security/PermissionCatalog.cs`). Business errors are `THROW` with a number from the
   module's block in `Inventory_Shipment.Repository/Database/SqlErrors.cs`, turned into ProblemDetails with a
   `code` the pages read: services return `Result` / `Result<T>` (`ErrorType` -> `ToProblem` in
   `Inventory_Shipment.API/Extensions/ResultExtensions.cs`: validation 400, not found 404, the rest 409; warehouse
   access 50010 is 403 with code `WAREHOUSE_ACCESS`), and a `THROW` arrives as `BusinessRuleException`.
   Cross-cutting rules live in one place each and every new endpoint goes through them: `Service/Security/ItemCosts.cs`
   (a cost a reader may not see leaves the API null, never 0), `IWarehouseAccessService` (where a user may move stock,
   said before the procedure runs; the ledger trigger repeats it), `PermissionCatalog.cs` (synced at start: texts, and
   every permission to the system roles only).
3. **Front end**: typed client in `src/api/`, pages in `src/pages/`, shared pieces in `src/components/`, and a section
   in `docs/frontend-conventions.md` for any new pattern.
4. Commit message: what changed, ending with `(prompt NN)`.

Conventions worth keeping:

- `*Utc` columns hold UTC and go out as ISO with `Z`; calendar dates (DocumentDate, Eta, ...) are plain dates.
- Costs per **base unit** in the **base currency**; documents keep their own currency and rate.
- Comments explain *why*, often opening with an upper-case summary sentence. Match the style of the file you edit.

## Checks before pushing

- Back end: `dotnet build Inventory_Shipment.API` (there is no test project; each script's Check section and the
  numbered test cases of its prompt are the tests).
- Front end: `npm run lint`, `npm run typecheck`, `npm run test`, `npm run build`.
- Database changes: apply `Schema.sql` to an **empty** database as well as to an existing one (the previous main's
  Schema.sql, then the new one twice: the second run must change nothing and grant nothing again).
- `tools/check-repo.sh` (what breaks the Windows PCs and Visual Studio: paths differing by capitals, reserved names,
  build leftovers, the .sqlproj file list); it runs as the pre-commit hook after `git config core.hooksPath .githooks`
  once per clone.

## Environments and branches

- One Ubuntu server runs two environments with Docker, each with its own web app, API and database
  (`deploy/README.md`); testing's, `Inventory_Shipment_Test`, can live in production's SQL Server, as its own login
  `inventory_test` (`deploy/README.md`, "One SQL Server for both environments"):
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
- A release is a pull request `main` -> `production` in **both** repositories, then `update.sh` (or the button) for
  production. No data is ever copied between the environments for a release: each API applies the new scripts to its
  own database at start (their one-time data steps included), and the schema compare of `deploy/README.md` ("Notes
  for the next release") only verifies that both databases then equal `DatabaseProject` - never Update / Apply from a
  schema compare tool.
- Never commit `deploy/.env` or `appsettings.Development.json`, and never ask for or repeat passwords, keys or server
  credentials.

## Working with the user

- Short, plain English. For anything they run, say **where**: on their PC, on the server, or in the browser.
- When asked for business prompts, follow "How we write prompts" in `docs/business-context.md`, continue the
  numbering from its prompt list, and check the code for what already exists before proposing a change.
