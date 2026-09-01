# US-MD-004 — Item Families (hierarchical tree) — SQL + VS Code prompts

One tree page replaces the planned Item Sub Groups / Item Categories pages: a sub group is a child
family. Unlimited depth; items (next story) may attach to a family at any level.

| Step | What | Who |
|------|------|-----|
| 1 | `Database\09_MasterData_ItemFamilies.sql` in SSMS on **Inventory_Shipment** (needs 01 + 03) | you (or the assistant) |
| 2 | **Prompt A** — backend | VS Code assistant |
| 3 | **Prompt B** — frontend (tree page) | VS Code assistant |

Agreed design: unlimited depth (all SQL hierarchy logic is iterative — no recursion cap); codes
auto-suggested from the parent (FAM-002 → FAM-002-01), editable, globally unique, never renamed on
move; a family can be active only if its parent is active — deactivating cascades to the whole
subtree; sibling names unique per parent; whole tree loaded at once (no server paging — paging
cannot work on a tree); delete only for leaves that nothing references.

Business-rule error numbers:

| Number | Meaning | HTTP | `code` |
|--------|---------|------|--------|
| 54000 | validation | 400 | `VALIDATION` |
| 54001 | Family Code already exists | 409 | `DUPLICATE_CODE` |
| 54002 | name already used under the same parent | 409 | `DUPLICATE_NAME` |
| 54003 | assigned to items / referenced — cannot delete | 409 | `REFERENCED` |
| 54004 | RowVersion changed | 409 | `CONCURRENCY` |
| 54005 | has child families — cannot delete | 409 | `HAS_CHILDREN` |
| 54006 | family / parent not found | 404 | `NOT_FOUND` |
| 54007 | circular hierarchy (parent is itself/descendant) | 400 | `CIRCULAR_HIERARCHY` |
| 54008 | parent family inactive | 400 | `PARENT_INACTIVE` |

---

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10, C# 13, nullable). You may
read and modify every file in it. Do not touch D:\VSProjects\Inventory_Shipment.Web in this task.

Copy the established Master Data pattern (Branches / Warehouses / Currencies): entities + DTOs in Model,
Dapper repositories over stored procedures with SqlErrors -> BusinessRuleException for THROW 5xxxx, services
returning Result with Code/Data, controllers with [HasPermission] and ResultExtensions (problem.code /
problem.data), PermissionCatalog synced at start-up, Repository\Database\Schema.sql embedded and applied at
start-up (batches split on GO). Schema per module - never dbo. No new NuGet packages. 0 build warnings.
Database: SQL Server default instance (Server=.), database Inventory_Shipment, Windows Authentication.
Dev sign-in: admin / Admin@12345.

Feature: US-MD-004 Item Families - a SELF-REFERENCING tree with UNLIMITED depth. One tree replaces the old
"Sub Groups" / "Categories" idea; items (future story) will reference a family at any level. Codes are stable
(never renamed on move). A family can be active only if its parent is active; deactivating cascades down.

The database work is written: D:\VSProjects\Inventory_Shipment\Database\09_MasterData_ItemFamilies.sql creates
masterdata.ItemFamilies (Id, ParentId NULL self-FK, FamilyCode NVARCHAR(50) unique, FamilyName NVARCHAR(150)
unique per parent, Description NVARCHAR(500) NULL, Level INT (1 = root, maintained by the procs), IsActive,
audit columns, RowVersion), masterdata.fn_ItemFamily_Subtree(@Id) and these procedures (error table in
docs/prompts/11-masterdata-itemfamilies.md, numbers 54000..54008):
  masterdata.usp_ItemFamily_Tree            -> ALL families flat (no paging) + ChildCount per row
  masterdata.usp_ItemFamily_Get @Id         -> one row + ChildCount
  masterdata.usp_ItemFamily_Lookup @ActiveOnly BIT = 1, @IncludeId INT = NULL -> flat dropdown data
  masterdata.usp_ItemFamily_NextChildCode @ParentId INT = NULL -> SuggestedCode (FAM-### / <parent>-##)
  masterdata.usp_ItemFamily_Create @FamilyCode, @FamilyName, @ParentId, @Description, @IsActive, @UserId, @NewId OUT
  masterdata.usp_ItemFamily_Update @Id, @FamilyCode, @FamilyName, @ParentId, @Description, @IsActive,
      @RowVersion BINARY(8), @UserId      (moves re-level the subtree; deactivation cascades)
  masterdata.usp_ItemFamily_SetActive @Id, @IsActive, @UserId   (deactivate cascades to the subtree)
  masterdata.usp_ItemFamily_Delete @Id   (54005 when it has children, 54003 when referenced)

TASK

1. Database: run the script (sqlcmd -S . -E -d Inventory_Shipment -i "D:\VSProjects\Inventory_Shipment\Database\09_MasterData_ItemFamilies.sql")
   and show its output; then append it to Repository\Database\Schema.sql under "-- ===== 09: Master Data -
   Item Families =====" without the USE batch and without the final report batch. Keep every GO and the guard batch.

2. Model
   - Entities/ItemFamily.cs: Id, ParentId?, FamilyCode, FamilyName, Description?, Level, IsActive, ChildCount,
     CreatedAtUtc, CreatedBy?, UpdatedAtUtc?, UpdatedBy?, byte[] RowVersion.
   - DTOs/MasterData/: ItemFamilyDto (id, parentId, familyCode, familyName, description, level, isActive,
     childCount, createdAtUtc, updatedAtUtc, rowVersion Base64); SaveItemFamilyRequest (FamilyCode [Required,
     StringLength(50, MinimumLength = 1)], FamilyName [Required, StringLength(150, MinimumLength = 1)],
     int? ParentId, Description [StringLength(500)], bool IsActive = true, string? RowVersion);
     SetItemFamilyStatusRequest (bool IsActive); ItemFamilyLookupDto (id, parentId, familyCode, familyName,
     level, isActive); NextCodeDto (suggestedCode).
   - PermissionCatalog: Permissions.MasterData.ItemFamiliesView/Create/Edit/Delete =
     "masterdata.itemfamilies.view|create|edit|delete", module "Master Data", sort 260..290, names/descriptions
     as in the SQL MERGE.

3. Repository: IItemFamilyRepository / ItemFamilyRepository - TreeAsync(), GetAsync(id), LookupAsync(activeOnly,
   includeId), NextChildCodeAsync(parentId), CreateAsync(...), UpdateAsync(...), SetActiveAsync(...),
   DeleteAsync(id). CommandType.StoredProcedure everywhere; register in AddRepositoryLayer.

4. Service: IItemFamilyService / ItemFamilyService + mapper. BusinessRuleException mapping: 54000 Validation;
   54001 Conflict DUPLICATE_CODE; 54002 Conflict DUPLICATE_NAME; 54003 Conflict REFERENCED; 54004 Conflict
   CONCURRENCY; 54005 Conflict HAS_CHILDREN; 54006 NotFound; 54007 Validation CIRCULAR_HIERARCHY; 54008
   Validation PARENT_INACTIVE. Register in AddServiceLayer.

5. API: ItemFamiliesController, route api/masterdata/item-families:
     GET    tree                          [HasPermission(masterdata.itemfamilies.view)] -> ItemFamilyDto[] (flat, client builds the tree)
     GET    {id}                          [view]            -> ItemFamilyDto / 404
     GET    lookup?activeOnly=&includeId= [Authorize] only  -> ItemFamilyLookupDto[]
     GET    next-code?parentId=           [Authorize] only  -> NextCodeDto
     POST                                 [create]  SaveItemFamilyRequest -> 201 ItemFamilyDto
     PUT    {id}                          [edit]    SaveItemFamilyRequest -> 200 ItemFamilyDto
     PUT    {id}/status                   [edit]    SetItemFamilyStatusRequest -> 204
     DELETE {id}                          [delete]  -> 204

6. Quality: dotnet build 0 warnings; API starts with "Database schema verified"; Scalar shows the endpoints.

VERIFY (token via POST /api/auth/login admin / Admin@12345) - curl each and show output:
  a. GET tree -> the seeded 9 families (4 roots; Motorcycles has children down to level 3).
  b. GET next-code?parentId={motorcyclesId} -> "FAM-001-04"; without parentId -> "FAM-005".
  c. POST { familyCode: "FAM-001-04", familyName: "Body Parts", parentId: Motorcycles } -> 201 level 2;
     same name under the same parent again -> 409 DUPLICATE_NAME; same code -> 409 DUPLICATE_CODE.
  d. PUT Electricals with parentId = Battery (its own child) -> 400 CIRCULAR_HIERARCHY.
  e. PUT Electricals moving it under Scooters -> 200; GET tree shows Battery/Lighting re-leveled under it;
     move it back.
  f. PUT {electricalsId}/status { isActive: false } -> 204 and Battery + Lighting are now inactive too;
     PUT Battery status active -> 400 PARENT_INACTIVE; reactivate Electricals, then Battery -> both 204.
  g. DELETE Motorcycles -> 409 HAS_CHILDREN; DELETE the "Body Parts" leaf -> 204.
  h. A user holding only masterdata.itemfamilies.view gets 403 on POST.
Report: script output, files added/changed, every verification result.
```

---

## Prompt B — Frontend (Item Families tree page)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite 8 + TypeScript, Mantine 9 +
mantine-datatable + @mantine/form + @mantine/modals + @mantine/notifications + @tabler/icons-react). Follow
docs/frontend-conventions.md and the shared components in src/components/ui (PageHeader, FilterBar with
AUTO-APPLY filters - no Filter button, DataTable, FormModal, StatusBadge, RowActions, notify, confirm). You may
read D:\VSProjects\Inventory_Shipment for reference but not change it. Backend endpoints exist under
api/masterdata/item-families: tree, {id}, lookup, next-code?parentId=, POST, PUT {id}, PUT {id}/status,
DELETE {id}. Error codes: DUPLICATE_CODE, DUPLICATE_NAME, REFERENCED, CONCURRENCY, HAS_CHILDREN, NOT_FOUND,
CIRCULAR_HIERARCHY, PARENT_INACTIVE (see docs/prompts/11-masterdata-itemfamilies.md in the API repo).
Dev: npm run dev, sign in admin / Admin@12345.

Feature: US-MD-004 Item Families - ONE hierarchical tree page under Master Data (unlimited depth). It REPLACES
the planned "Item Sub Groups" and "Item Categories" pages: remove those two entries from src/navigation.ts if
present; keep "Item Families" (masterdata.itemfamilies.view), breadcrumb "Setup › Master Data › Item Families".

DATA MODEL OF THE PAGE: GET tree returns ALL families flat ({ id, parentId, familyCode, familyName, description,
level, isActive, childCount, ... }). Load once into state and do EVERYTHING client-side (search, filters,
expand/collapse) - there is deliberately no server paging: paging cannot work on a tree. Refetch after every
mutation.

TASK

1. src/api/masterdata/itemFamilies.ts: typed functions for every endpoint, reusing request<T> from http.ts.

2. Item Families page:
   - PageHeader: "Item Families", subtitle "View and manage item families in a hierarchical structure.",
     actions: More Actions menu (Expand All, Collapse All) + "+ New Family" (create permission).
   - FilterBar (auto-apply, client-side): search (code or name), Status (All/Active/Inactive), Family
     (searchable Select of all families - filters the view to that family's SUBTREE), Clear Filters.
   - Tree grid built on the shared DataTable with a computed visibleRows array (no paging footer):
     * columns: Family Code (chevron IconChevronRight/Down when childCount > 0, indentation of
       level * 20 px, folder icon, then the code), Family Name, Parent Family (name or "—"), Description
       (truncated with Tooltip), Children (childCount), Status (StatusBadge), Actions.
     * expand/collapse per row; expansion state in a Set<number>, persisted to localStorage in try/catch;
       Expand All / Collapse All update it.
     * while SEARCHING or FILTERING: show every matching row plus ALL its ancestors (so context is kept),
       auto-expanded; highlight is not required. Clearing filters restores the persisted expansion.
   - Row actions (RowActions + one extra): Add child family (IconPlus, create permission - opens the modal
     with Parent preselected to this row), Edit, Activate/Deactivate, Delete - gated by permissions.
   - New/Edit modal (FormModal + @mantine/form), title "New Item Family" / "Edit Item Family":
     * Family Code (withAsterisk): when creating and the user has not typed a code manually, fetch
       GET next-code?parentId=<selected parent> whenever the Parent changes and fill the suggestion
       (editable; stop auto-filling after the user edits it).
     * Family Name (withAsterisk).
     * Parent Family: searchable Select built from the loaded tree - option label indented with dashes per
       level ("— Engine Parts"), value = id, clearable, helper "Leave blank to create a root family". When
       EDITING, exclude the family itself and all its descendants from the options (that is what prevents a
       circular hierarchy). Show "(inactive)" suffix on inactive parents and disable choosing them for an
       active family.
     * Description (Textarea autosize minRows 3, 0/500 counter).
     * Active (Switch, default on). When turning it OFF on a family with descendants, no extra dialog here -
       the cascade warning happens on save: if the family has children, first confirm() "Deactivating
       <name> also deactivates its N sub-families. Continue?" (count descendants client-side).
   - Activate/Deactivate row action: deactivate with descendants -> same cascade confirm; activate under an
     inactive parent -> the API answers PARENT_INACTIVE - show notify.error with its message.
   - Delete: confirm() danger; HAS_CHILDREN -> dialog "This family cannot be deleted because it contains child
     families or is assigned to existing items. You may deactivate it instead." with a "Deactivate instead"
     action; REFERENCED -> same dialog wording (the customer asked for one combined message).
   - Error mapping in the modal: DUPLICATE_CODE -> under Family Code; DUPLICATE_NAME -> under Family Name;
     CIRCULAR_HIERARCHY / PARENT_INACTIVE -> under Parent Family; CONCURRENCY -> notify + refetch.
   - Success toasts: "Item family created successfully." / updated / deleted, then refetch the tree.

3. Quality: npm run typecheck, npm run lint, npm run build clean; responsive at 390 px (tree indentation
   preserved, horizontal scroll inside the table container); view-only users see no New/child/edit/delete.

VERIFY (API running) and report each with screenshots at 1440 px and 390 px:
  a. Seeded tree renders: 4 roots, Motorcycles expandable to level 3 (Battery under Electricals); chevrons only
     on rows with children; expansion survives a page reload.
  b. "+ New Family" with parent Motorcycles pre-fills code FAM-001-04; saving shows the success toast and the
     new row under Motorcycles.
  c. Row action "Add child family" on Scooters opens the modal with Scooters preselected and code FAM-002-01.
  d. Search "batt" shows Battery WITH its ancestors Motorcycles > Electricals, auto-expanded; Status=Inactive
     filter works; Family filter on Electricals shows only its subtree; Clear Filters restores.
  e. Editing Electricals: the Parent dropdown does NOT contain Electricals, Battery or Lighting; moving it under
     Scooters re-renders the subtree there; move it back.
  f. Deactivate Electricals -> cascade confirm mentions 2 sub-families; after confirming, Battery and Lighting
     show Inactive; activating Battery alone shows the parent-inactive error; reactivate Electricals then Battery.
  g. Delete on Motorcycles shows the combined cannot-delete dialog with "Deactivate instead"; deleting a leaf
     works with the danger confirm.
  h. Sign in as a view-only user: tree visible, no action buttons.
Report: files added/changed, navigation changes, every verification result.
```
