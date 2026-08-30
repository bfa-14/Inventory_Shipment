# US-MD-002 — Warehouse Setup — SQL + VS Code prompts

| Step | What | Who |
|------|------|-----|
| 1 | `Database\07_MasterData_Warehouses.sql` in SSMS on **Inventory_Shipment** (needs 06 applied) | you (or the assistant) |
| 2 | **Prompt A** — backend: Model / Repository / Service / API + embed the script | VS Code assistant |
| 3 | **Prompt B** — frontend: Warehouses page, New/Edit modal, Branch / Site dropdowns | VS Code assistant |

Prerequisite: US-MD-001 (Branches) is implemented — the warehouse code mirrors it one-to-one.

Business-rule error numbers thrown by the procedures:

| Number | Meaning | HTTP | `code` |
|--------|---------|------|--------|
| 52000 | validation (required field) | 400 | `VALIDATION` |
| 52001 | Warehouse Code already exists | 409 | `DUPLICATE_CODE` |
| 52002 | another active Main Warehouse exists — confirm replacement | 409 | `MAIN_WAREHOUSE_EXISTS` (+ `data.currentMainWarehouse`) |
| 52003 | contains inventory / referenced — cannot delete | 409 | `REFERENCED` |
| 52004 | RowVersion changed (concurrency) | 409 | `CONCURRENCY` |
| 52005 | Main Warehouse must stay active / cannot be deactivated or deleted | 400 | `MAIN_WAREHOUSE_PROTECTED` |
| 52006 | not found | 404 | `NOT_FOUND` |
| 52007 | Branch / Site not found or inactive | 400 | `BRANCH_INACTIVE` |

---

## Prompt A — Backend (Model, Repository, Service, API)

```text
You are working on D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10, C# 13, nullable). You may
read and modify every file in it. Do not touch D:\VSProjects\Inventory_Shipment.Web in this task.

The Branches feature (US-MD-001) is already implemented and is the pattern to copy exactly:
Model/Entities/Branch.cs, Model/DTOs/MasterData/*, Model/Common/PagedResult.cs, Result.Code/Result.Data,
Repository/Interfaces/IBranchRepository.cs + Implementations/BranchRepository.cs (stored procedures via Dapper,
SqlErrors + BusinessRuleException for THROW 5xxxx), Service/Interfaces/IBranchService.cs +
Implementations/BranchService.cs (+ Mapping/BranchMapper.cs), API/Controllers/MasterData/BranchesController.cs
([HasPermission] per action, ResultExtensions with problem.code / problem.data), Security/PermissionCatalog.cs
(module "Master Data"), Repository\Database\Schema.sql (embedded, applied at start-up, batches split on GO).
Conventions: one SQL schema per module (security, masterdata, inventory, shipment - never dbo); services return
Result and never throw for expected failures; UTC timestamps; no new NuGet packages; 0 build warnings.
Database: SQL Server default instance (Server=.), database Inventory_Shipment, Windows Authentication.
Dev sign-in: admin / Admin@12345 (Admin = system role, holds every permission).

Feature: US-MD-002 Warehouse Setup - warehouses belong to a Branch / Site; inventory will later be tracked per
warehouse; items will have a default warehouse.

The database work is written: D:\VSProjects\Inventory_Shipment\Database\07_MasterData_Warehouses.sql creates
masterdata.Warehouses (Id, WarehouseCode NVARCHAR(20) unique, WarehouseName NVARCHAR(150), BranchId INT FK ->
masterdata.Branches, Address NVARCHAR(500) null, IsMainWarehouse BIT, IsActive BIT, CreatedAtUtc, CreatedBy,
UpdatedAtUtc, UpdatedBy, RowVersion ROWVERSION), the permissions masterdata.warehouses.view / create / edit /
delete and a seed WH-001 Main Warehouse on the main branch. Rules in SQL (THROW): 52000 validation, 52001 duplicate
code, 52002 another active Main Warehouse exists (retry with @ReplaceMainWarehouse = 1 after confirmation), 52003
referenced (contains inventory / other records), 52004 RowVersion mismatch, 52005 Main Warehouse must stay
active / cannot be deactivated or deleted, 52006 not found, 52007 Branch / Site not found or inactive.
Procedures:
  masterdata.usp_Warehouse_Search @Search, @BranchId INT NULL, @IsActive BIT NULL, @IsMainWarehouse BIT NULL,
      @SortColumn (WarehouseCode|WarehouseName|BranchName|Address|IsMainWarehouse|IsActive|CreatedAtUtc),
      @SortDirection, @PageNumber, @PageSize -> rows with the warehouse columns + BranchCode + BranchName + TotalCount
  masterdata.usp_Warehouse_Get @Id / usp_Warehouse_GetMain -> same columns (joined with the branch)
  masterdata.usp_Warehouse_Lookup @ActiveOnly BIT = 1, @BranchId INT NULL, @IncludeId INT NULL
      -> Id, WarehouseCode, WarehouseName, BranchId, BranchCode, BranchName, IsMainWarehouse, IsActive
  masterdata.usp_Branch_Lookup @ActiveOnly BIT = 1, @IncludeId INT NULL -> Id, BranchCode, BranchName, IsMainBranch, IsActive
  masterdata.usp_Warehouse_Create @WarehouseCode, @WarehouseName, @BranchId, @Address, @IsMainWarehouse, @IsActive,
      @ReplaceMainWarehouse, @UserId, @NewId INT OUTPUT
  masterdata.usp_Warehouse_Update @Id, @WarehouseCode, @WarehouseName, @BranchId, @Address, @IsMainWarehouse,
      @IsActive, @ReplaceMainWarehouse, @RowVersion BINARY(8), @UserId
  masterdata.usp_Warehouse_SetActive @Id, @IsActive, @UserId      masterdata.usp_Warehouse_Delete @Id

TASK

1. Database: run the script (sqlcmd -S . -E -d Inventory_Shipment -i "D:\VSProjects\Inventory_Shipment\Database\07_MasterData_Warehouses.sql")
   and show its output; then append it to Repository\Database\Schema.sql under "-- ===== 07: Master Data -
   Warehouses =====" without the USE batch and without the final report batch. Keep every GO and the guard batch.

2. Model
   - Entities/Warehouse.cs: Id, WarehouseCode, WarehouseName, BranchId, BranchCode, BranchName (read-only, from the
     join), Address?, IsMainWarehouse, IsActive, CreatedAtUtc, CreatedBy?, UpdatedAtUtc?, UpdatedBy?, byte[] RowVersion.
   - DTOs/MasterData/: WarehouseDto (id, warehouseCode, warehouseName, branchId, branchCode, branchName, address,
     isMainWarehouse, isActive, createdAtUtc, updatedAtUtc, rowVersion Base64); SaveWarehouseRequest (WarehouseCode
     [Required, StringLength(20, MinimumLength = 1)], WarehouseName [Required, StringLength(150, MinimumLength = 1)],
     BranchId [Required, Range(1, int.MaxValue)], Address [StringLength(500)], bool IsMainWarehouse = false,
     bool IsActive = true, bool ReplaceMainWarehouse = false, string? RowVersion); SetWarehouseStatusRequest
     (bool IsActive); WarehouseQuery (string? Search, int? BranchId, bool? IsActive, bool? IsMainWarehouse,
     string SortBy = "WarehouseCode", string SortDir = "asc", int Page = 1, int PageSize = 10 [Range(1, 200)]);
     BranchLookupDto (id, branchCode, branchName, isMainBranch, isActive); WarehouseLookupDto (id, warehouseCode,
     warehouseName, branchId, branchCode, branchName, isMainWarehouse, isActive).
   - Security/PermissionCatalog.cs: Permissions.MasterData.WarehousesView / WarehousesCreate / WarehousesEdit /
     WarehousesDelete = "masterdata.warehouses.view|create|edit|delete", four PermissionDefinition entries,
     module "Master Data", names "View warehouses" / "Create warehouses" / "Edit warehouses" / "Delete warehouses",
     sort order 140..170.

3. Repository
   - IBranchRepository: add Task<IReadOnlyList<BranchLookup>> LookupAsync(bool activeOnly, int? includeId, CancellationToken)
     (usp_Branch_Lookup) - use a small entity/record BranchLookup or reuse Branch with the columns returned.
   - IWarehouseRepository / WarehouseRepository (CommandType.StoredProcedure everywhere, SqlErrors.Wrap on
     business-rule SqlExceptions): SearchAsync(WarehouseQuery) -> (items, totalCount); GetByIdAsync; GetMainAsync;
     LookupAsync(bool activeOnly, int? branchId, int? includeId); CreateAsync(Warehouse, replaceMain, userId) -> id
     (@NewId output); UpdateAsync(Warehouse, replaceMain, byte[]? rowVersion, userId); SetActiveAsync; DeleteAsync.
   - Register in AddRepositoryLayer.

4. Service
   - Mapping/WarehouseMapper.cs (Warehouse -> WarehouseDto / WarehouseLookupDto; BranchLookup -> BranchLookupDto).
   - IBranchService: add LookupAsync(bool activeOnly, int? includeId) -> Result<IReadOnlyList<BranchLookupDto>>.
   - IWarehouseService / WarehouseService: SearchAsync -> Result<PagedResult<WarehouseDto>>; GetAsync; LookupAsync
     (activeOnly, branchId, includeId) -> Result<IReadOnlyList<WarehouseLookupDto>>; CreateAsync(request, userId) ->
     Result<WarehouseDto> (re-read after insert); UpdateAsync(id, request, userId); SetActiveAsync(id, isActive,
     userId); DeleteAsync(id) -> Result. Map BusinessRuleException.Number:
       52000 -> Validation "VALIDATION" (SQL message)          52001 -> Conflict "DUPLICATE_CODE"
       52002 -> Conflict "MAIN_WAREHOUSE_EXISTS", Data = new { currentMainWarehouse = <WarehouseDto of GetMainAsync()> }
       52003 -> Conflict "REFERENCED", message exactly: "This warehouse cannot be deleted because it contains inventory
                or is referenced by other records. You may deactivate the warehouse instead."
       52004 -> Conflict "CONCURRENCY"    52005 -> Validation "MAIN_WAREHOUSE_PROTECTED"
       52006 -> NotFound "NOT_FOUND"      52007 -> Validation "BRANCH_INACTIVE" (SQL message)
     Log create/update/delete/status changes at Information with the acting user id.
   - Register in AddServiceLayer.

5. API
   - BranchesController: add GET /api/masterdata/branches/lookup?activeOnly=true&includeId= -> BranchLookupDto[].
     This endpoint needs only an authenticated user ([Authorize], no HasPermission) because every master-data form
     that has a Branch / Site dropdown needs it, not only users who manage branches.
   - Controllers/MasterData/WarehousesController.cs, route "api/masterdata/warehouses":
       GET    /                      [HasPermission(Permissions.MasterData.WarehousesView)] query WarehouseQuery -> 200 PagedResult<WarehouseDto>
       GET    /lookup                [Authorize] (authenticated only) ?activeOnly=true&branchId=&includeId= -> 200 WarehouseLookupDto[]
       GET    /main                  [HasPermission(WarehousesView)] -> 200 | 404
       GET    /{id:int}              [HasPermission(WarehousesView)] -> 200 | 404
       POST   /                      [HasPermission(WarehousesCreate)] body SaveWarehouseRequest -> 201 CreatedAtAction | 400 | 409
       PUT    /{id:int}              [HasPermission(WarehousesEdit)]   body SaveWarehouseRequest -> 200 WarehouseDto | 400 | 404 | 409
       PATCH  /{id:int}/status       [HasPermission(WarehousesEdit)]   body SetWarehouseStatusRequest -> 200 WarehouseDto | 400 | 404
       DELETE /{id:int}              [HasPermission(WarehousesDelete)] -> 204 | 400 | 404 | 409
     Route order: declare /lookup and /main before /{id:int} (or rely on the int constraint).
   - dotnet build with 0 warnings.

6. VERIFY (API running; token from POST /api/auth/login as admin; show request + response for each):
   a. GET /api/auth/me lists the four masterdata.warehouses.* permissions.
   b. GET /api/masterdata/branches/lookup -> the active branches; GET /api/masterdata/warehouses -> WH-001 on the main
      branch, isMainWarehouse true, branchName filled.
   c. POST {"warehouseCode":"WH-002","warehouseName":"Kolwezi Depot","branchId":<BR-002 id or any active branch>,
      "address":"Zone industrielle, Kolwezi"} -> 201 with branchCode/branchName.
   d. POST the same warehouseCode again -> 409 DUPLICATE_CODE.
   e. POST with branchId = <an inactive branch> (deactivate one first via PATCH /api/masterdata/branches/{id}/status)
      -> 400 BRANCH_INACTIVE; with branchId = 999999 -> 400 BRANCH_INACTIVE.
   f. POST {"warehouseCode":"WH-003","warehouseName":"Likasi Depot","branchId":<active>,"isMainWarehouse":true}
      -> 409 MAIN_WAREHOUSE_EXISTS with data.currentMainWarehouse.warehouseCode = "WH-001"; again with
      "replaceMainWarehouse":true -> 201; GET /main -> WH-003; WH-001 now isMainWarehouse false.
   g. PATCH /{WH-003 id}/status {"isActive":false} -> 400 MAIN_WAREHOUSE_PROTECTED; DELETE /{WH-003 id} -> 400.
   h. PATCH /{WH-002 id}/status {"isActive":false} -> 200 isActive false; GET /lookup -> WH-002 absent;
      GET /lookup?activeOnly=false -> present; GET /lookup?includeId=<WH-002 id> -> present.
   i. DELETE /api/masterdata/branches/{branch that has a warehouse} -> 409 REFERENCED (the branch delete-protection
      now sees the warehouse); DELETE /api/masterdata/warehouses/{WH-002 id} -> 204.
   j. PUT with a stale rowVersion -> 409 CONCURRENCY. GET ...?search=likasi&branchId=<id>&sortBy=BranchName&sortDir=desc -> 200.
   k. Restore WH-001 as main (PUT with isMainWarehouse true + replaceMainWarehouse true) -> 200.
   l. A user without masterdata.warehouses.* -> GET /api/masterdata/warehouses -> 403, but GET /lookup -> 200.
7. Report: files added/changed, output of every verification step, and anything implemented differently.
```

---

## Prompt B — Frontend (Warehouses page)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite + TypeScript strict, react-router v7,
plain CSS, lucide-react). You may read the API project at D:\VSProjects\Inventory_Shipment for reference but must
not change it. The Branches / Sites page (US-MD-001) exists and is the pattern to copy exactly:
src/pages/masterdata/BranchesPage.tsx + BranchFormModal.tsx, src/api/masterdata/branches.ts, the navigation model
(src/navigation.ts), the shell (white sidebar, breadcrumb, top bar, footer), src/components/ui/* (Modal,
ConfirmDialog, Badge, DataTable, SearchInput, useToast), src/config.ts (PAGE_SIZE_DEFAULT, PAGE_SIZE_OPTIONS),
src/api/http.ts (request<T>, ApiError with .status / .messages / .code / .data), useAuth().hasPermission.
Dev API through the Vite proxy (/api). Sign in: admin / Admin@12345.

Reference design (customer figure): identical to the Branches page with these differences -
- Breadcrumb "Setup › Master Data › Warehouses"; title "Warehouses"; subtitle "View and manage warehouses.";
  buttons "⋮ More Actions ▾" and "+ New Warehouse".
- Filter row: search "Search by warehouse code or name..." | Branch / Site select (All + one entry per branch,
  "CODE – Name") | Status select (All / Active / Inactive) | Is Main Warehouse select (All / Yes / No) |
  "⟳ Clear Filters" | "⚲ Filter".
- Table columns: # · Warehouse Code ⇅ · Warehouse Name ⇅ · Branch / Site ⇅ · Address ⇅ · Is Main Warehouse ⇅
  (amber ★ + "Yes" / "No") · Status ⇅ (Active green pill / Inactive grey pill) · Actions (edit pencil blue,
  activate/deactivate power, delete trash red). Footer "Showing 1 to 8 of 8 entries" + page size + pagination.
- Modal "New Warehouse" / "Edit Warehouse" (560 px): Warehouse Code * | Warehouse Name * (two columns);
  Branch / Site * (full-width select, placeholder "Select branch / site"); Address (textarea, 3 rows);
  Is Main Warehouse * (checkbox "Yes, this is the main warehouse") | Active * (toggle); footer "Cancel" /
  "Save Warehouse" (primary blue).

Backend (implemented) - base path /api/masterdata/warehouses, bearer token required:
  GET    /?search=&branchId=&isActive=&isMainWarehouse=&sortBy=WarehouseCode&sortDir=asc&page=1&pageSize=10
         -> PagedResult<WarehouseDto>
  GET    /{id}      GET /main      GET /lookup?activeOnly=true&branchId=&includeId=  -> WarehouseLookupDto[]
  POST   /  body SaveWarehouseRequest -> 201 WarehouseDto
  PUT    /{id} body SaveWarehouseRequest (with rowVersion) -> 200 WarehouseDto
  PATCH  /{id}/status { isActive } -> 200 WarehouseDto      DELETE /{id} -> 204
  GET    /api/masterdata/branches/lookup?activeOnly=true&includeId=  -> BranchLookupDto[] { id, branchCode, branchName, isMainBranch, isActive }
  WarehouseDto { id, warehouseCode, warehouseName, branchId, branchCode, branchName, address, isMainWarehouse,
                 isActive, createdAtUtc, updatedAtUtc, rowVersion }
  SaveWarehouseRequest { warehouseCode, warehouseName, branchId, address?, isMainWarehouse, isActive,
                         replaceMainWarehouse, rowVersion? }
  Problem-details codes: 409 DUPLICATE_CODE · 409 MAIN_WAREHOUSE_EXISTS (problem.data.currentMainWarehouse) ·
  409 REFERENCED · 409 CONCURRENCY · 400 MAIN_WAREHOUSE_PROTECTED · 400 BRANCH_INACTIVE · 400 VALIDATION · 404 · 403
  Permissions: masterdata.warehouses.view / create / edit / delete.

TASK

1. Types + API client: WarehouseDto, SaveWarehouseRequest, SetWarehouseStatusRequest, WarehouseQuery,
   WarehouseLookupDto, BranchLookupDto in src/api/types.ts; src/api/masterdata/warehouses.ts (search, get,
   getMain, lookup, create, update, setStatus, remove); add branchesApi.lookup(activeOnly, includeId).

2. Navigation: make Master Data > Warehouses functional (route /setup/master-data/warehouses, permission
   masterdata.warehouses.view); breadcrumb from the model.

3. Warehouses page - src/pages/masterdata/WarehousesPage.tsx, guarded by masterdata.warehouses.view. Copy the
   Branches page behaviour exactly (filters applied on Filter / Enter, Clear Filters, server-side sort + paging,
   page resets on filter/sort change, skeleton, empty state "No warehouses found.", inline API errors, More Actions
   with Refresh + Export CSV, permission-gated buttons), plus:
   - the Branch / Site filter select is loaded once from branchesApi.lookup(activeOnly: false) (all branches,
     inactive ones suffixed " (inactive)");
   - the Branch / Site column shows "branchName" (tooltip with the code);
   - Deactivate/Delete icons disabled with tooltip for the main warehouse.

4. Modal - src/pages/masterdata/WarehouseFormModal.tsx (mode create | edit): fields as in the design. Branch / Site
   options come from branchesApi.lookup(activeOnly: true, includeId: warehouse?.branchId) so an edit form still
   shows the current branch even when it is inactive (label suffixed " (inactive)"); the select is required and
   shows "Branch / Site is required." when empty. Defaults: Active on, Is Main Warehouse off. Save flow, success
   toasts "Warehouse created successfully." / "Warehouse updated successfully.", the MAIN_WAREHOUSE_EXISTS
   confirmation ("{data.currentMainWarehouse.warehouseCode} – {warehouseName} is currently the Main Warehouse.
   Make {this code} the Main Warehouse instead?" -> resend with replaceMainWarehouse: true), DUPLICATE_CODE under
   the code field, BRANCH_INACTIVE under the Branch / Site select, CONCURRENCY alert with Reload, field errors
   mapped, everything else inline - exactly like the Branches modal.

5. Row actions: Delete with ConfirmDialog -> "Warehouse deleted successfully."; on 409 REFERENCED show the API
   message "This warehouse cannot be deleted because it contains inventory or is referenced by other records. You
   may deactivate the warehouse instead." with a "Deactivate instead" button. Activate/Deactivate with confirmation
   -> "Warehouse activated." / "Warehouse deactivated."; show the API message on 400 (MAIN_WAREHOUSE_PROTECTED or
   BRANCH_INACTIVE when re-activating a warehouse whose branch is inactive).

6. Refactor for reuse (small, no behaviour change): if BranchesPage and WarehousesPage now share large identical
   blocks (filter card layout, table footer/pagination, status pill, star cell, action icon group, "main entity"
   confirmation flow), extract them into src/components/masterdata/* and use them in both pages. Keep both pages
   pixel-identical to the designs after the refactor.

7. Responsive as the Branches page; npm run typecheck, npm run lint, npm run build clean; no TODOs, no mock data.

VERIFY (API + npm run dev, signed in as admin)
  a. Master Data > Warehouses shows WH-001 on the main branch with the star; breadcrumb correct.
  b. New Warehouse without a branch -> "Branch / Site is required."; create WH-002 on another branch -> toast, listed
     with its branch name; Branch / Site filter = that branch shows only WH-002.
  c. Create WH-003 as main -> confirmation names WH-001; confirm -> WH-003 main, WH-001 "No".
  d. Deactivate a branch that has a warehouse (Branches page), then edit that warehouse: its branch still shows
     (suffixed inactive); trying to move another warehouse to that branch shows the error under the select.
  e. Delete a branch that has warehouses (Branches page) -> the "referenced" message with "Deactivate instead".
  f. Deactivate WH-002 -> Inactive; filter Status = Inactive; delete WH-002 -> removed; main warehouse actions disabled.
  g. Sort by Branch / Site, paging with > 10 rows, 1440 px and 390 px widths.
  h. A user with only masterdata.warehouses.view sees the page without New/Edit/Delete; without the permission the
     menu item is hidden and the route shows Forbidden.
Report: files added/changed (including any shared components extracted), screenshots, and every verification result.
```
