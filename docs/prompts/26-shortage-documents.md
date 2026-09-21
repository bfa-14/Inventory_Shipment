# Batch 5 — Shortage planning documents (Shortage List + Shortage Document), transit quantities, PC per container

Replaces the "Shortages" page of batch 4 (`25-purchase-shortages.md`, point 4 of its Prompt B and the
`api/inventory/shortages` endpoints of its Prompt A) with the customer's study: a shortage is a **saved planning
document** — Draft (editable, recalculable, deletable) → Posted (read-only historical snapshot; purchase orders are
created from it and carry the Shortage No.). Numbering `SHR-2026-000001`.

Rule (per line, base units): `Stock + Transit = Current Inventory + Transit`; `Total Expected Stock = Current
Inventory + Transit + Outstanding Order`; `Expected Requirement = Expected Monthly Sales × Lead Time (Month)`;
`Shortage = max(0, Requirement − Total Expected Stock)`; `Coverage = Total Expected Stock ÷ Expected Monthly Sales`;
`Container Requirement = Required Qty × packing ÷ PC per Container`. Expected Monthly Sales = sales of the last
"Months of history" (default 3) in the warehouse ÷ months, overridable per line. Transit = quantities marked as
shipped on open purchase orders (new "Mark as shipped" action) not yet received.

SQL: `22_Inventory_ShortageDocuments.sql` (requires 19–21; run after batch 4 is applied). Then Prompt A (API), Prompt B (Web).

## Prompt A — Backend

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern as in the purchase documents (repository over procedures + TVP, service, controller, export).

Script already written: /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment/Database/22_Inventory_ShortageDocuments.sql
- read its header. Summary:
- inventory.DocumentTypes + YearInNumber, NextNumberYear (usp_DocumentType_List / _Update re-created: _Update has a new
  optional last parameter @YearInNumber); type SHR (Shortage Plan, SHR-YYYY-000001, number at creation);
  inventory.DocumentSequences now per type + branch + year (no API change).
- inventory.Items + PcPerContainer; usp_Item_Get returns it; usp_Item_SetPurchasing has a new optional last parameter
  @PcPerContainer.
- purchase.PurchaseDocumentLines + ShippedQuantityBase; purchase.tvp_ShippedLine (LineId, ShippedQuantityBase);
  purchase.usp_PurchaseDocument_MarkShipped(@Id, @Lines TVP (empty = everything shipped), @RowVersion, @UserId) - open
  POs only; purchase.PurchaseDocuments + SourceShortageId; purchase.usp_PurchaseDocument_Get re-created: header +
  SourceShortageId / SourceShortageNumber, lines + ShippedQuantityBase, TransitBase.
- inventory.ShortageDocuments / ShortageDocumentLines (snapshot columns: CurrentInventoryBase, TransitBase,
  OutstandingOrderBase, StockPlusTransitBase, TotalExpectedStockBase, ExpectedMonthlySalesBase,
  ExpectedMonthlySalesManual, EffectiveMonthlySales, LeadTimeMonths, ExpectedRequirementBase, ShortageBase,
  CoverageMonths, PurchaseItemUnitId, PurchaseUnitName, PurchasePackingFormula, RequiredQty (purchase unit),
  RequiredBase, PcPerContainer, ContainerRequirement, MinQuantity, MaxQuantity, LastCost, Notes) / ShortageDocumentAudit;
  inventory.tvp_ShortageLine (LineNumber, ItemId, RequiredQty NULL = suggested, ExpectedMonthlySalesManual NULL,
  PcPerContainer NULL = item value, Notes).
- inventory.usp_Shortage_Calculate(@WarehouseId, @SupplierId, @LeadTimeMonths, @MonthsOfHistory, @ItemFamilyId,
  @BrandId, @Search, @OnlyShortages) -> live rows (same columns as the lines + SuggestedRequiredQty, SoldInPeriodBase,
  SupplierId/Name/IsDefault, BrandName, FamilyName). inventory.usp_Shortage_Report was DROPPED.
- inventory.usp_ShortageDocument_Search(@Search, @WarehouseId, @BranchId, @SupplierId, @Status 1|2, @CreatedBy,
  @DateFrom, @DateTo, sort DocumentNumber|DocumentDate|Description|WarehouseName|SupplierName|Status|CreatedAtUtc,
  page) (+ PurchaseOrders count); usp_ShortageDocument_Get(@Id) -> 4 result sets: header (totals: TotalLines,
  TotalShortageBase, TotalRequiredBase, TotalContainers, ContainersRounded, ContainerUtilizationPct, CalculatedAtUtc,
  posted info), lines, purchase orders created from it, audit; usp_ShortageDocument_Save(@Id NULL = create,
  @Description, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @LeadTimeMonths DECIMAL, @MonthsOfHistory,
  @Notes, @Lines TVP, @RowVersion, @UserId, @NewId OUT) - takes the live figures at save time;
  usp_ShortageDocument_Recalculate(@Id, @RowVersion, @UserId) (draft: refresh live figures, keep manual values);
  usp_ShortageDocument_Post(@Id, @RowVersion, @UserId); usp_ShortageDocument_Delete(@Id, @UserId) (drafts);
  usp_ShortageDocument_CreatePurchaseOrder(@Id, @DocumentDate, @ExpectedDate, @UserId, @NewId OUT) (posted only ->
  one draft PO for the header supplier/branch/warehouse with SourceShortageId).
Errors 66xxx -> codes: 66000 VALIDATION ("Line N: ..."), 66004 CONCURRENCY, 66005 NOT_DRAFT, 66006 NOT_FOUND,
66009 NO_LINES, 66010 INVALID_STATUS, 66011 NOTHING_TO_ORDER. Permissions (module Inventory):
inventory.shortages.view 950 / create 960 / post 970 / delete 980.

TASK
1. Run the script, show its output, append it to Repository/Database/Schema.sql under "-- ===== 22 =====" (no USE,
   no self-test / report batches; keep every guarded block).
2. Document types: DocumentTypeDto + yearInNumber; UpdateDocumentTypeRequest + YearInNumber (pass it to the proc).
3. Items: ItemDto + pcPerContainer; Create/Update requests + PcPerContainer (through usp_Item_SetPurchasing).
4. Purchase: PurchaseDocumentDto + sourceShortageId, sourceShortageNumber; line DTO + shippedQuantityBase,
   transitBase; POST api/purchase/documents/{id}/mark-shipped { lines: [{ lineId, shippedQuantityBase }] (empty =
   all), rowVersion } [purchase.orders.create] -> PurchaseDocumentDto.
5. Shortage documents - REPLACE the batch-4 shortage endpoints:
   Model (DTOs/Inventory/Shortages/): ShortageDocumentListDto, ShortageDocumentDto (header + lines[] + purchaseOrders[]
   + audit[] + canEdit/canRecalculate/canPost/canDelete (draft) / canCreatePurchaseOrder (posted)),
   SaveShortageDocumentRequest (Description [Required, 200], DocumentDate, BranchId, WarehouseId, SupplierId,
   LeadTimeMonths (decimal > 0), MonthsOfHistory (1..36, default 3), Notes?, Lines[] { LineNumber, ItemId,
   RequiredQty?, ExpectedMonthlySalesManual?, PcPerContainer?, Notes? }, RowVersion?), ShortageCalculateQuery
   (warehouseId, supplierId?, leadTimeMonths = 6, monthsOfHistory = 3, itemFamilyId?, brandId?, search?,
   onlyShortages = true), ShortageLiveRowDto, ShortageDocumentQuery (search, warehouseId, branchId, supplierId, status,
   createdBy, dateFrom, dateTo, sortBy, sortDir, page, pageSize), CreatePurchaseOrderFromShortageRequest
   (documentDate?, expectedDate?).
   Repository IShortageDocumentRepository (Calculate, Search, Get x4, Save with the TVP, Recalculate, Post, Delete,
   CreatePurchaseOrder). Service IShortageDocumentService (permission per action; Export(id) -> xlsx with the header
   block, the lines with every snapshot column and the totals; ExportLive(query) -> xlsx of the live rows).
   API ShortageDocumentsController route api/inventory/shortages:
     GET  calculate?query          [view]   -> ShortageLiveRowDto[]  (live rows to load into a document)
     GET  ?query                   [view]   -> PagedResult<ShortageDocumentListDto>
     GET  {id}                     [view]   -> ShortageDocumentDto
     POST                          [create] -> 201 (draft, number assigned)
     PUT  {id}                     [create]
     POST {id}/recalculate         [create] -> ShortageDocumentDto
     POST {id}/post                [post]   -> ShortageDocumentDto
     DELETE {id}                   [delete] -> 204
     GET  {id}/export              [view]   -> xlsx "Shortage_<number>.xlsx"
     POST {id}/create-purchase-order [purchase.orders.create] -> the new PurchaseDocumentDto (PO draft)
   Remove the old GET report / create-orders endpoints of batch 4.
6. PermissionCatalog: the 4 shortage codes. Build 0 warnings; "Database schema verified".

VERIFY (token admin / Admin@12345; TVS-AP160 with default supplier SUP-0001, some sales in the last 3 months, an
open PO with 10 pieces for the warehouse) with curl, show output:
  a. GET calculate?warehouseId=&leadTimeMonths=6&monthsOfHistory=3&onlyShortages=false -> TVS-AP160 row:
     currentInventoryBase = on-hand, outstandingOrderBase 10, transitBase 0, expectedMonthlySalesBase = sold/3,
     expectedRequirementBase = sales x 6, shortageBase / suggestedRequiredQty consistent.
  b. POST mark-shipped on the PO with 4 base units -> line transitBase 4; GET calculate -> transitBase 4,
     outstandingOrderBase 6; stockPlusTransit and totalExpectedStock updated.
  c. POST a shortage draft (description, warehouse, branch, SUP-0001, lead time 6, history 3, 2 lines: TVS-AP160
     with requiredQty null -> suggested; a second item with expectedMonthlySalesManual 50, pcPerContainer 20) -> 201
     documentNumber "SHR-2026-000001", lines carry the snapshot, totals (containers = sum of requirements, rounded up,
     utilization %).
  d. Post an Inventory In for TVS-AP160 (stock changes) -> GET the draft: unchanged; POST recalculate -> current
     inventory updated, requiredQty and manual sales kept; PUT changes requiredQty -> ok.
  e. POST {id}/post -> Posted; PUT -> 409 NOT_DRAFT; DELETE -> 409 NOT_DRAFT; post another Inventory In -> GET still
     shows the old snapshot (historical); GET export -> xlsx.
  f. POST create-purchase-order -> PO draft with lines = requiredQty in the purchase unit, sourceShortageNumber set;
     GET the shortage -> purchaseOrders[] lists it; create-purchase-order on a draft shortage -> 409 INVALID_STATUS.
  g. A second shortage this year -> SHR-2026-000002; a user with view only -> 403 on POST.
Report: files changed/removed, every verification result.
```

## Prompt B — Frontend

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared ui
components, document-page skeleton, DocumentListPage). Frontend only. Backend: api/inventory/shortages (calculate,
list, get, create, update, recalculate, post, delete, export, create-purchase-order), api/purchase/documents/{id}/
mark-shipped, items with pcPerContainer, document types with yearInNumber; lookups (branches, warehouses, parties
?type=Supplier, item-families, brands, users/lookup for Created By). Error codes: VALIDATION ("Line N: ..."),
CONCURRENCY, NOT_DRAFT, NOT_FOUND, NO_LINES, INVALID_STATUS, NOTHING_TO_ORDER. Permissions:
inventory.shortages.view/create/post/delete, purchase.orders.create. Dev: npm run dev, admin / Admin@12345.

Feature: REPLACE the batch-4 Shortages page with two pages: Shortage List and Shortage Document (customer study).
Caption everywhere: "Lead Time (Month)" (never "Planning Period").

TASK
1. Navigation: INVENTORY > "Shortages" (inventory.shortages.view) -> /inventory/shortages (list); document routes
   /inventory/shortages/new and /inventory/shortages/:id.
2. SHORTAGE LIST (DocumentListPage): FilterBar (Shortage No. / Description search, Warehouse, Branch, Supplier,
   Status Draft/Posted, Created By, Date from/to); columns: Shortage No., Description, Warehouse, Branch, Supplier,
   Lead Time (Month), Lines, Containers (rounded), POs (count, link), Status badge (Draft grey / Posted green),
   Created By, Created On, Posted By, Posted On; RowActions: View, Edit (draft, create perm), Delete (draft, delete
   perm, confirm), Print, Export to Excel. "+ New Shortage" (create perm). No bulk actions needed here.
3. SHORTAGE DOCUMENT (/new, /:id):
   Header card "Shortage Plan": Shortage No. (read-only; "Assigned on save" for new), Description* (TextInput, focus),
   Status badge, Created By / Created On (read-only, system), Date* (default today), Warehouse* (quantities),
   Branch* (for the PO; default = the warehouse's branch), Supplier* (searchable, parties?type=Supplier),
   Lead Time (Month)* (NumberInput, decimals allowed, default 6), Months of history (NumberInput 1-36, default 3,
   help text "Expected Monthly Sales = sales of the last N months ÷ N"), Notes.
   Load items (draft only): a toolbar "Load items" opening a drawer/modal with filters (Family tree, Brand, search,
   "Only shortages" toggle default on, "Only this supplier's items" toggle default on) that calls GET calculate with
   the header values; preview table with checkboxes (all shortage rows pre-checked); "Add selected (n)" appends them
   as lines (existing items are skipped with a notify). Also "Recalculate" (saved drafts: POST recalculate, then
   reload; unsaved changes -> ask to save first) and "Remove line" per row.
   Lines grid (DataTable, client-side sort, horizontal scroll, sticky first column): #, Item (code link + name),
   Current Inventory, Transit Qty, Outstanding Order Qty, Stock + Transit, Total Expected Stock, Expected Monthly
   Sales (editable NumberInput with 2 decimals; shows the computed value greyed when no override, a "manual" badge
   when overridden and a reset icon), Lead Time (Month) (read-only, from header), Expected Requirement, Shortage Qty
   (red when > 0), Coverage (months, 2 decimals; red when < Lead Time), Required Qty (editable NumberInput, integer,
   in the purchase unit shown as suffix, default = suggested; "Reset to suggested" icon), PC per Container (editable,
   default item value), Container Requirement (2 decimals), Min, Max, Last cost, Notes (editable), Delete.
   Client-side the derived cells recompute live from the edited inputs using the same formulas (the API values win
   after save). Summary card: Items, Total Shortage (base units), Total Required (base units), Containers (sum,
   e.g. 7.35), Containers rounded (8), Utilization % (progress bar), Last calculated at.
   Action bar (sticky; menu below 768 px): draft/new -> Save Draft, Save & Post (confirm "Post this shortage plan?
   The figures will be frozen as a historical snapshot."), Recalculate, Delete, Print, Export to Excel, Create
   Purchase Order (disabled with tooltip "Post the plan first"); posted -> Print, Export to Excel, Create Purchase
   Order (confirm; -> POST create-purchase-order -> notify with the PO number and navigate to the PO draft), Back.
   Posted documents are fully read-only (inputs replaced by text) and show a banner "Posted by X on Y - historical
   snapshot, values are not recalculated". A "Purchase orders" card lists the POs created from this plan (number,
   date, status, amount, link) and the audit trail card shows Created / Updated / Recalculated / Posted / POCreated.
   Print: a print-friendly view (window.print with a print stylesheet: header block + lines table + totals, no
   navigation), reachable from the list and the document.
   Validation / errors as the other document pages ("Line N:" highlights the row; NO_LINES, NOT_DRAFT, CONCURRENCY
   (reload), NOTHING_TO_ORDER as notify). Unsaved-changes guard.
4. Purchase Order page: posted PO gets the action "Mark as shipped" (dialog listing the lines with Ordered /
   Received / Shipped so far and an editable Shipped quantity per line, "All shipped" button) -> POST mark-shipped;
   the lines grid shows "In transit" (transitBase) for POs; a "Source: Shortage SHR-2026-000001" chip on POs created
   from a plan (link to the shortage document).
5. Item Definition: "PC per Container" field in the Purchasing section (integer, optional).
6. Configuration > Document Types: "Year in number" column + checkbox in the edit modal.
7. docs/frontend-conventions.md: "Shortage plans" section (formulas, draft vs posted behaviour, PO creation).
8. Quality: typecheck / lint / build clean; all breakpoints (the wide lines grid scrolls inside its card);
   permission gating (view-only users see read-only plans; no create -> no New / Load items / Recalculate).

VERIFY (API running; TVS-AP160 with sales in the last months, an open PO with a shipped quantity) with screenshots
at 1440 and 390:
  a. New Shortage: fill the header, Load items -> shortage rows pre-checked -> Add -> grid shows every column with
     the formulas (check one row by hand: Requirement = monthly sales x lead time; Shortage = Requirement - Total
     Expected; Coverage = Total Expected / monthly sales); edit Required Qty -> Container Requirement and the
     summary containers/utilization update; override Expected Monthly Sales -> badge "manual", Shortage updates.
  b. Save Draft -> SHR-2026-000001 in the header and the list; reopen -> values as saved; post an Inventory In ->
     Recalculate -> Current Inventory changes, Required Qty and manual sales kept.
  c. Save & Post -> read-only banner; post another Inventory In -> the document still shows the old figures;
     Print opens the print view; Export downloads the xlsx.
  d. Create Purchase Order -> PO draft opens with the Required Qty lines and the "Source: Shortage" chip; the
     shortage's Purchase orders card lists it.
  e. PO page: Mark as shipped 4 pieces -> In transit 4; a new shortage's Load items shows Transit 4 / Outstanding
     reduced by 4.
  f. List filters auto-apply (status, supplier, created by, dates); Delete only on drafts; view-only user sees no
     buttons.
Report: files added/changed/removed, navigation changes, every verification result.
```
