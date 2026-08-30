# US-MD-001 — Branch / Site Setup — SQL + VS Code prompts

Deliverables for this user story:

| Step | What | Who |
|------|------|-----|
| 1 | `Database\06_MasterData_Branches.sql` in SSMS on **Inventory_Shipment** (needs 01 + 03 already applied) | you (or the assistant) |
| 2 | **Prompt A** — backend: Model / Repository / Service / API + embed the script | VS Code assistant |
| 3 | **Prompt B** — frontend: Master Data section, Branches / Sites page, New/Edit modal | VS Code assistant |

Schema convention: `security` (users, roles), **`masterdata`** (branches, warehouses, item families,
categories, units of measure, brands…), `inventory`, `shipment`. Nothing in `dbo`.

Business-rule error numbers thrown by the procedures (the API maps them to HTTP responses):

| Number | Meaning | HTTP | `code` in problem details |
|--------|---------|------|---------------------------|
| 51000 | validation (required field) | 400 | `VALIDATION` |
| 51001 | Branch Code already exists | 409 | `DUPLICATE_CODE` |
| 51002 | another active Main Branch exists — confirm replacement | 409 | `MAIN_BRANCH_EXISTS` (+ `data.currentMainBranch`) |
| 51003 | referenced by other records — cannot delete | 409 | `REFERENCED` |
| 51004 | RowVersion changed (concurrency) | 409 | `CONCURRENCY` |
| 51005 | Main Branch must stay active / cannot be deactivated or deleted | 400 | `MAIN_BRANCH_PROTECTED` |
| 51006 | not found | 404 | `NOT_FOUND` |

---

## Prompt A — Backend (Model, Repository, Service, API)

```text
You are working on D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10, C# 13, nullable). You may
read and modify every file in it. Do not touch D:\VSProjects\Inventory_Shipment.Web in this task.

Architecture and conventions (already in place - follow them exactly):
- Inventory_Shipment.Model: entities, DTOs, Options, Common/Result.cs (Result / Result<T> with ErrorType
  Validation | Unauthorized | Forbidden | NotFound | Conflict | Locked), Security/PermissionCatalog.cs (static class
  Permissions with nested classes of code constants + Permissions.All catalog, synced to the database at start-up).
- Inventory_Shipment.Repository: Dapper over ISqlConnectionFactory ("await using var connection =
  _connectionFactory.Create()"), interfaces in Interfaces/, implementations in Implementations/, stored procedures
  called with CommandType.StoredProcedure, business-rule errors thrown by SQL (THROW 5xxxx) are turned into a
  typed exception (see Exceptions/ and Database/SqlErrors.cs), DependencyInjection.AddRepositoryLayer.
- Inventory_Shipment.Service: interfaces in Interfaces/, implementations in Implementations/, services return
  Result and never throw for expected failures, Mapping/ for entity -> DTO, DependencyInjection.AddServiceLayer.
- Inventory_Shipment.API: controllers with [ApiController], [HasPermission("...")] on every action,
  Extensions/ResultExtensions.cs maps Result to ActionResult / RFC 9457 problem details, Scalar docs at /scalar.
  Repository\Database\Schema.sql is an embedded resource applied on every start-up (batches split on GO, all
  idempotent). Database objects use one schema per module: security, masterdata, inventory, shipment - never dbo.
- No new NuGet packages (restore is offline). Timestamps are UTC (.AsUtc() when mapping). 0 build warnings.
Database: SQL Server default instance (Server=.), database Inventory_Shipment, Windows Authentication.
Dev sign-in: admin / Admin@12345 (Admin = system role, holds every permission).

Feature: US-MD-001 Branch / Site Setup - master data of company branches/sites, later referenced by warehouses,
inventory locations and transactions.

The database work is already written: D:\VSProjects\Inventory_Shipment\Database\06_MasterData_Branches.sql creates
schema masterdata, table masterdata.Branches (Id, BranchCode NVARCHAR(20) unique, BranchName NVARCHAR(150),
Address NVARCHAR(500) null, IsMainBranch BIT, IsActive BIT, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy,
RowVersion ROWVERSION), the procedures below, the permissions masterdata.branches.view / create / edit / delete
(module "Master Data") and a seed main branch BR-001 Head Office. Rules enforced in SQL with THROW:
  51000 validation, 51001 duplicate code, 51002 another active Main Branch exists (retry with
  @ReplaceMainBranch = 1 after the user confirms), 51003 referenced by other records, 51004 RowVersion mismatch,
  51005 Main Branch must stay active / cannot be deactivated or deleted, 51006 not found.
Procedures:
  masterdata.usp_Branch_Search @Search, @IsActive BIT NULL, @IsMainBranch BIT NULL, @SortColumn
      (BranchCode|BranchName|Address|IsMainBranch|IsActive|CreatedAtUtc), @SortDirection (ASC|DESC), @PageNumber,
      @PageSize -> page rows with every Branches column plus TotalCount
  masterdata.usp_Branch_Get @Id -> one row or none
  masterdata.usp_Branch_GetMain -> the active main branch (0 or 1 row)
  masterdata.usp_Branch_Create @BranchCode, @BranchName, @Address, @IsMainBranch, @IsActive, @ReplaceMainBranch,
      @UserId, @NewId INT OUTPUT
  masterdata.usp_Branch_Update @Id, @BranchCode, @BranchName, @Address, @IsMainBranch, @IsActive,
      @ReplaceMainBranch, @RowVersion BINARY(8) (NULL skips the check), @UserId
  masterdata.usp_Branch_SetActive @Id, @IsActive, @UserId
  masterdata.usp_Branch_Delete @Id

TASK

1. Database
   a. Run the script: sqlcmd -S . -E -d Inventory_Shipment -i "D:\VSProjects\Inventory_Shipment\Database\06_MasterData_Branches.sql"
      (or Invoke-Sqlcmd). Show its output (the two result sets at the end).
   b. Append the script to Inventory_Shipment.Repository\Database\Schema.sql under a banner
      "-- ===== 06: Master Data - Branches =====", without the "USE [Inventory_Shipment];" batch and without the
      final report batch (the two SELECTs + PRINT). Keep every GO and the guard batch at the top.

2. Model (Inventory_Shipment.Model)
   a. Common/Result.cs: add two optional members so the API can return machine-readable details:
        string? Code   (e.g. "DUPLICATE_CODE") and object? Data (extra payload for the client).
      Keep every existing Success/Failure signature working; add overloads such as
        Result.Failure(ErrorType type, string error, string code, object? data = null) and the same on Result<T>.
   b. Common/PagedResult.cs: sealed class PagedResult<T> { IReadOnlyList<T> Items; int Page; int PageSize;
      int TotalCount; int TotalPages => ceil; bool HasNext; bool HasPrevious }.
   c. Entities/Branch.cs: Id, BranchCode, BranchName, Address?, IsMainBranch, IsActive, CreatedAtUtc, CreatedBy?,
      UpdatedAtUtc?, UpdatedBy?, byte[] RowVersion.
   d. DTOs/MasterData/:
      - BranchDto: id, branchCode, branchName, address, isMainBranch, isActive, createdAtUtc, updatedAtUtc,
        rowVersion (Base64 string of the 8 bytes).
      - SaveBranchRequest (used for create and update): BranchCode [Required, StringLength(20, MinimumLength = 1)],
        BranchName [Required, StringLength(150, MinimumLength = 1)], Address [StringLength(500)],
        bool IsMainBranch = false, bool IsActive = true, bool ReplaceMainBranch = false, string? RowVersion (update only).
      - SetBranchStatusRequest: bool IsActive.
      - BranchQuery: string? Search, bool? IsActive, bool? IsMainBranch, string SortBy = "BranchCode",
        string SortDir = "asc", int Page = 1 [Range(1, int.MaxValue)], int PageSize = 10 [Range(1, 200)].
   e. Security/PermissionCatalog.cs: add
        public static class MasterData { BranchesView = "masterdata.branches.view", BranchesCreate =
        "masterdata.branches.create", BranchesEdit = "masterdata.branches.edit", BranchesDelete =
        "masterdata.branches.delete" }
      and the four PermissionDefinition entries in Permissions.All with Module = "Master Data", names
      "View branches" / "Create branches" / "Edit branches" / "Delete branches", sort order 100..130
      (the catalog sync gives them to the Admin role automatically).

3. Repository (Inventory_Shipment.Repository)
   a. Generalize the business-rule error handling: Exceptions/BusinessRuleException.cs (int Number, string Message)
      raised for any SqlException with Number between 50000 and 59999 (keep SecurityRuleException working - either
      make it derive from BusinessRuleException or map both; do not break existing code). Put the helper in
      Database/SqlErrors.cs (IsBusinessRule(SqlException), Wrap(SqlException)).
   b. Interfaces/IBranchRepository.cs + Implementations/BranchRepository.cs, all calls with CommandType.StoredProcedure:
      - Task<(IReadOnlyList<Branch> Items, int TotalCount)> SearchAsync(BranchQuery query, CancellationToken)
        (map SortBy/SortDir to @SortColumn/@SortDirection; read TotalCount from the first row, 0 when no rows)
      - Task<Branch?> GetByIdAsync(int id, CancellationToken)
      - Task<Branch?> GetMainAsync(CancellationToken)
      - Task<int> CreateAsync(Branch branch, bool replaceMainBranch, int? userId, CancellationToken)
        (DynamicParameters with @NewId direction Output)
      - Task UpdateAsync(Branch branch, bool replaceMainBranch, byte[]? rowVersion, int? userId, CancellationToken)
      - Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken)
      - Task DeleteAsync(int id, CancellationToken)
      Every method: catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex)) => throw SqlErrors.Wrap(ex).
   c. Register in DependencyInjection.AddRepositoryLayer.

4. Service (Inventory_Shipment.Service)
   a. Mapping/BranchMapper.cs: Branch -> BranchDto (rowVersion = Convert.ToBase64String).
   b. Interfaces/IBranchService.cs + Implementations/BranchService.cs:
      - SearchAsync(BranchQuery) -> Result<PagedResult<BranchDto>>
      - GetAsync(int id) -> Result<BranchDto> (NotFound)
      - CreateAsync(SaveBranchRequest, int userId) -> Result<BranchDto> (returns the created row re-read from the DB)
      - UpdateAsync(int id, SaveBranchRequest, int userId) -> Result<BranchDto> (RowVersion: Base64 -> byte[];
        invalid Base64 -> Validation)
      - SetActiveAsync(int id, bool isActive, int userId) -> Result<BranchDto>
      - DeleteAsync(int id) -> Result
      Map BusinessRuleException.Number:
        51000 -> Validation, code "VALIDATION", message from SQL
        51001 -> Conflict, code "DUPLICATE_CODE", "A branch with this Branch Code already exists."
        51002 -> Conflict, code "MAIN_BRANCH_EXISTS", message from SQL, Data = new { currentMainBranch = <BranchDto of
                 GetMainAsync()> } so the UI can ask "Replace BR-001 Head Office?"
        51003 -> Conflict, code "REFERENCED", "This branch cannot be deleted because it is referenced by other records.
                 You may deactivate the branch instead."
        51004 -> Conflict, code "CONCURRENCY", message from SQL
        51005 -> Validation, code "MAIN_BRANCH_PROTECTED", message from SQL
        51006 -> NotFound, code "NOT_FOUND", "Branch not found."
      Log every create/update/delete/status change at Information with the acting user id.
   c. Register in DependencyInjection.AddServiceLayer.

5. API (Inventory_Shipment.API)
   a. Extensions/ResultExtensions.cs: when Result.Code is set add problem.Extensions["code"]; when Result.Data is set
      add problem.Extensions["data"]. Keep the existing "errors" extension.
   b. Controllers/MasterData/BranchesController.cs, route "api/masterdata/branches", [ApiController],
      [Produces("application/json")], ProducesResponseType attributes like the other controllers:
        GET    /                     [HasPermission(Permissions.MasterData.BranchesView)]   query BranchQuery -> 200 PagedResult<BranchDto>
        GET    /{id:int}             [HasPermission(BranchesView)]                            -> 200 BranchDto | 404
        GET    /main                 [HasPermission(BranchesView)]                            -> 200 BranchDto | 404
        POST   /                     [HasPermission(BranchesCreate)]  body SaveBranchRequest  -> 201 CreatedAtAction(GetById) | 400 | 409
        PUT    /{id:int}             [HasPermission(BranchesEdit)]    body SaveBranchRequest  -> 200 BranchDto | 400 | 404 | 409
        PATCH  /{id:int}/status      [HasPermission(BranchesEdit)]    body SetBranchStatusRequest -> 200 BranchDto | 400 | 404
        DELETE /{id:int}             [HasPermission(BranchesDelete)]                          -> 204 | 400 | 404 | 409
      The acting user id comes from User.GetUserId().
   c. dotnet build with 0 warnings.

6. VERIFY - run the API (dotnet run --project ...\Inventory_Shipment.API --launch-profile https), sign in as admin
   (POST /api/auth/login) and, with the token, show request + response of each step (curl -k or Invoke-RestMethod):
   a. GET /api/auth/me contains the four masterdata.branches.* permissions.
   b. GET /api/masterdata/branches?page=1&pageSize=10 -> 200, items contains BR-001 (isMainBranch true), totalCount >= 1.
   c. POST {"branchCode":"BR-002","branchName":"Kolwezi Branch","address":"Av. Kasai 12, Kolwezi","isMainBranch":false,"isActive":true} -> 201.
   d. POST the same branchCode again -> 409 with code "DUPLICATE_CODE".
   e. POST {"branchCode":"BR-003","branchName":"Likasi Branch","isMainBranch":true} -> 409 code "MAIN_BRANCH_EXISTS"
      with data.currentMainBranch.branchCode = "BR-001".
   f. Same body with "replaceMainBranch":true -> 201; GET /main -> BR-003; GET /{BR-001 id} -> isMainBranch false.
   g. PATCH /{BR-003 id}/status {"isActive":false} -> 400 code "MAIN_BRANCH_PROTECTED".
   h. DELETE /{BR-003 id} -> 400 code "MAIN_BRANCH_PROTECTED"; DELETE /{BR-002 id} -> 204.
   i. PUT /{BR-001 id} with the rowVersion from an earlier GET after another PUT changed the row -> 409 code "CONCURRENCY".
   j. GET ...?search=likasi&isActive=true&sortBy=BranchName&sortDir=desc -> 200 with the expected row.
   k. Restore: PUT BR-001 with isMainBranch true and replaceMainBranch true -> 200; BR-003 is no longer main.
   l. Sign in with a user that lacks the permissions (create one via POST /api/users with no roles) -> GET /api/masterdata/branches -> 403.
7. Report: files added/changed, the output of every verification step, and anything you implemented differently.
```

---

## Prompt B — Frontend (Master Data section + Branches / Sites page)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite + TypeScript strict, react-router v7
package "react-router", plain CSS, lucide-react icons if already installed - otherwise you may add it; no other UI
framework). You may read the API project at D:\VSProjects\Inventory_Shipment for reference but must not change it.
Existing pieces to REUSE, not rewrite: src/api/http.ts (request<T>(), ApiError with .status, .messages and
.problem - the raw problem details), src/auth/AuthProvider.tsx + useAuth() (user, hasPermission(code)),
src/auth/ProtectedRoute.tsx (permission prop), the application shell (sidebar + top bar + content container),
src/navigation.ts (menu model), src/components/ui/* (Modal, ConfirmDialog, Badge, DataTable, SearchInput, useToast),
src/components/layout/PageHeader.tsx. Dev API: https://localhost:7089 through the Vite proxy (/api). Sign in:
admin / Admin@12345.

Reference designs: two figures were provided by the customer (list page and New Branch modal). Their layout:
- Left sidebar, WHITE background, 240 px, company logo at the top (src/assets/katanga-logo.png), items with icons:
  Dashboard · Inventory ▸ · Purchase Planning ▸ · Purchase Orders · Invoices · Shipment & Containers ▸ ·
  Costs & Payments ▸ · Documents · Reports; then a small grey section label "BACKOFFICE" followed by
  Master Data ▾ (Branches / Sites, Warehouses, Item Families, Item Sub Groups, Item Categories, Units of Measure,
  Brands) · Users & Permissions ▸ · Configuration ▸ · Integration · Audit & Logs ▸; at the very bottom
  "Collapse Menu". Active item: light-blue background #EEF3FF, blue text #2563EB, blue dot bullet for sub-items.
  Text #1F2937, inactive icons #6B7280.
- Top bar, white: breadcrumb "Setup › Master Data › Branches / Sites" on the left above the page title; on the
  right a global search input ("Search anything..."), a bell with a red badge count, and a user chip (avatar,
  "Admin User", "Administrator") with a dropdown.
- Content area background #F5F7FB. Page header: title "Branches / Sites" (24 px, 700), subtitle "View and manage
  company branches / sites." (grey), right side: "⋮ More Actions ▾" (white outline button) and "+ New Branch"
  (primary blue #2563EB, white text).
- A white card (radius 12 px, subtle border #E5E7EB) containing: a filter row [search input with magnifier
  "Search by branch code or name..." | Status select (All / Active / Inactive) | Is Main Branch select (All / Yes / No)
  | "⟳ Clear Filters" outline button | "⚲ Filter" outline button]; below it the table with columns
  # · Branch Code ⇅ · Branch Name ⇅ · Address ⇅ · Is Main Branch ⇅ · Status ⇅ · Actions.
  Is Main Branch shows an amber star ★ + "Yes" for the main branch and "No" otherwise. Status is a pill badge:
  Active = green (#DCFCE7 bg, #15803D text), Inactive = grey (#E5E7EB bg, #374151 text). Actions: blue pencil
  (edit) and red trash (delete) icon buttons. Table footer: "Showing 1 to 8 of 8 entries" on the left, pagination
  (‹ 1 ›) on the right.
- Page footer (full width, small grey text): "© 2026 Katanga TVS Motor Company. All rights reserved." left,
  "Powered by MAY solutions" centre, "Inspired by Mr. Issa Awada" right (the two names in blue).
- Modal "New Branch" (560 px, radius 12 px): fields in two columns - Branch Code * | Branch Name *; full-width
  Address (textarea, 3 rows); then Is Main Branch * (checkbox "Yes, this is the main branch") | Active * (toggle
  switch, blue when on, label "Active"); footer right-aligned: "Cancel" (outline) and "Save Branch" (primary).
  When editing, the same modal titled "Edit Branch" with the values populated.
Match these designs closely (spacing, colours, typography "Segoe UI"/Inter). If the current shell has a dark
sidebar from an earlier iteration, restyle it to this white design - these figures are the reference from now on.

Backend (already implemented) - base path /api/masterdata/branches, every endpoint needs a bearer token:
  GET    /?search=&isActive=&isMainBranch=&sortBy=BranchCode&sortDir=asc&page=1&pageSize=10
         -> PagedResult<BranchDto> { items, page, pageSize, totalCount, totalPages, hasNext, hasPrevious }
  GET    /{id} -> BranchDto      GET /main -> BranchDto | 404
  POST   /   body SaveBranchRequest -> 201 BranchDto
  PUT    /{id} body SaveBranchRequest (include rowVersion) -> 200 BranchDto
  PATCH  /{id}/status body { isActive } -> 200 BranchDto
  DELETE /{id} -> 204
  BranchDto { id, branchCode, branchName, address, isMainBranch, isActive, createdAtUtc, updatedAtUtc, rowVersion }
  SaveBranchRequest { branchCode, branchName, address?, isMainBranch, isActive, replaceMainBranch, rowVersion? }
  Errors are RFC 9457 problem details; problem.code tells you why:
    409 DUPLICATE_CODE · 409 MAIN_BRANCH_EXISTS (problem.data.currentMainBranch = BranchDto) · 409 REFERENCED ·
    409 CONCURRENCY · 400 MAIN_BRANCH_PROTECTED · 400 VALIDATION (or the ASP.NET "errors" object) · 404 NOT_FOUND · 403
  Permissions (in user.permissions from /api/auth/me): masterdata.branches.view / create / edit / delete.

TASK

1. Types and API client
   - src/api/types.ts: add BranchDto, SaveBranchRequest, SetBranchStatusRequest, BranchQuery, PagedResult<T>.
   - src/api/http.ts: make sure ApiError exposes the parsed problem details (problem.code, problem.data) - add a
     typed getter `code: string | undefined` and `data: unknown` if missing. Do not change how tokens/refresh work.
   - src/api/masterdata/branches.ts: branchesApi.search(query), get(id), getMain(), create(body), update(id, body),
     setStatus(id, isActive), remove(id). Build the query string from BranchQuery, omitting empty values.
   - src/config.ts: export const PAGE_SIZE_DEFAULT = 10 and PAGE_SIZE_OPTIONS = [10, 25, 50].

2. Navigation and shell
   - src/navigation.ts: model the full menu from the reference (sections, items, sub-items, icons, permission code
     per item, comingSoon flag). Functional now: Dashboard (/), Master Data > Branches / Sites
     (/setup/master-data/branches, permission masterdata.branches.view), Users & Permissions > Users / Roles /
     Permissions / Login audit (the existing Security pages and their permissions). Everything else is comingSoon:
     rendered greyed with a small "Soon" tag, not clickable. Items whose permission the user lacks are hidden.
     Groups expand/collapse; the group containing the active route is expanded on load.
   - Shell: apply the white sidebar / top bar / breadcrumb / footer design described above. Breadcrumb comes from
     the navigation model (section > group > item). Keep the existing collapse behaviour (icon-only sidebar,
     remembered in localStorage) and the mobile drawer under 900 px. The global search box and the bell are visual
     only for now (search does nothing yet; bell shows 0). The user chip keeps the existing menu
     (Change password / Sign out everywhere / Sign out).

3. Branches / Sites page - src/pages/masterdata/BranchesPage.tsx (route /setup/master-data/branches, guarded by
   permission masterdata.branches.view)
   - State: query { search, isActive, isMainBranch, sortBy, sortDir, page, pageSize }, data (PagedResult), loading,
     error. Loads from the API on mount and whenever query changes. Filters are applied when the user clicks
     "Filter" or presses Enter in the search box (not on every keystroke); "Clear Filters" resets everything to
     defaults and reloads. Changing sort or page reloads immediately. Page resets to 1 when filters or sort change.
   - PageHeader with title, subtitle, "More Actions" dropdown (items: "Refresh", "Export CSV" - exports the currently
     loaded rows client-side) and "+ New Branch" (visible only with masterdata.branches.create).
   - Filter card exactly as in the reference. Status select values: "" (All) | "true" | "false"; Is Main Branch:
     "" | "true" | "false".
   - Table (DataTable): # = (page-1)*pageSize + index + 1; sortable headers for Branch Code, Branch Name, Address,
     Is Main Branch, Status (click toggles asc/desc, arrow icon shows direction); Address wraps on two lines;
     Is Main Branch cell: amber star + "Yes" when isMainBranch else "No"; Status pill; Actions column: Edit (pencil,
     permission edit), Activate/Deactivate (power icon, permission edit; tooltip shows the action), Delete (trash,
     permission delete). Icons disabled with a tooltip when the row is the main branch and the action is
     Deactivate/Delete ("The main branch cannot be deactivated/deleted").
   - Footer: "Showing {from} to {to} of {totalCount} entries", page-size selector (PAGE_SIZE_OPTIONS) and
     pagination (‹ page numbers ›; show up to 5 numbers with ellipsis).
   - Loading: skeleton rows; empty: "No branches found." with a hint to clear filters; API error: inline Alert.

4. New / Edit Branch modal - src/pages/masterdata/BranchFormModal.tsx
   - Props: mode "create" | "edit", branch?: BranchDto, onClose, onSaved(branch). Title "New Branch" / "Edit Branch".
   - Fields and defaults as in the reference: Branch Code (required, max 20, trimmed), Branch Name (required,
     max 150), Address (optional, max 500, textarea), Is Main Branch (checkbox, default false), Active (toggle,
     default true for create; on edit shows the current value). Client-side validation shows messages under the
     fields; the Save button is disabled while saving.
   - Save flow: create -> POST; edit -> PUT with the branch's rowVersion. On success: onSaved(dto) -> parent closes
     the modal, reloads the list and shows the toast "Branch created successfully." or "Branch updated successfully."
   - When the API answers 409 with code MAIN_BRANCH_EXISTS: open a ConfirmDialog
     "{data.currentMainBranch.branchCode} – {branchName} is currently the Main Branch. Make {this code} the Main
     Branch instead?" with buttons "Replace Main Branch" / "Cancel"; on confirm resend the same request with
     replaceMainBranch: true.
   - Other errors: 409 DUPLICATE_CODE -> message under Branch Code ("A branch with this Branch Code already
     exists."); 409 CONCURRENCY -> inline alert with the message and a "Reload" link that re-fetches the branch into
     the form; 400 with field errors -> map them to the fields; anything else -> inline alert with ApiError.messages.

5. Row actions
   - Delete: ConfirmDialog (danger) "Delete branch {code} – {name}? This cannot be undone." -> DELETE -> reload +
     toast "Branch deleted successfully." On 409 REFERENCED show the API message in an error dialog:
     "This branch cannot be deleted because it is referenced by other records. You may deactivate the branch instead."
     with a secondary button "Deactivate instead" that performs the deactivation.
   - Activate / Deactivate: ConfirmDialog -> PATCH status -> reload + toast "Branch activated." / "Branch deactivated."
     On 400 MAIN_BRANCH_PROTECTED show the API message.
   - Edit: opens the modal in edit mode with the row's data.

6. Responsive: below 900 px the filter row stacks (search full width, selects side by side, buttons full width),
   the table scrolls horizontally inside the card, the modal uses one column and 92 vw width.

7. Quality: npm run typecheck, npm run lint and npm run build clean; no any-typed code; every string the user sees
   matches the wording above; no mock data; nothing left as TODO.

VERIFY (API running, npm run dev, sign in as admin)
  a. Sidebar shows the full menu from the reference with Branches / Sites active under Master Data; breadcrumb reads
     Setup › Master Data › Branches / Sites.
  b. The list shows BR-001 Head Office with the star and "Yes", Active badge, "Showing 1 to 1 of 1 entries".
  c. New Branch: leave fields empty -> validation messages; create BR-002 "Kolwezi Branch" -> toast, list refreshed.
  d. Create BR-003 with "Yes, this is the main branch" -> confirmation dialog names BR-001; confirm -> BR-003 is the
     main branch, BR-001 shows "No".
  e. Edit BR-002 (change the name) -> "Branch updated successfully."; try to create another branch with code BR-002
     -> error under Branch Code.
  f. Deactivate BR-002 -> Inactive badge; filter Status = Inactive shows only BR-002; Clear Filters shows all.
  g. Delete BR-002 -> confirmation -> removed. The Deactivate/Delete icons of the main branch are disabled with tooltips.
  h. Sort by Branch Name desc, then page size 10 with more than 10 rows (create a few) -> pagination works and
     "Showing 11 to N of N entries" is right.
  i. Sign in as a user without masterdata.branches.* permissions -> the Master Data > Branches / Sites item is hidden
     and /setup/master-data/branches shows the Forbidden page; a user with only ...view sees no New/Edit/Delete controls.
  j. Check at 1440 px and 390 px widths.
Report: files added/changed, screenshots of the list, the modal and the confirmation dialog, and the result of every
verification step.
```
