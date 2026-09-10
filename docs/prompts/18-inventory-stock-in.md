# Inventory In / Out documents + Stock Movements ledger — SQL + VS Code prompts

Run order: `Database\15_Inventory_StockDocuments.sql` in SSMS (needs 07, 08, 11, 12, 14) → Prompt A → Prompt B.

First document family, built on the Sales Invoice skeleton (header / quick item search / editable lines /
attachments / totals; Draft → Posted → Cancelled). Also created: `inventory.DocumentTypes` (configuration of
all 8 document kinds: family, stock direction, numbering prefix + sequence, number at draft or at post, reason
required), `inventory.StockReasons`, the `inventory.StockMovements` ledger with `fn_StockOnHand` /
`vw_StockBalance`, real On Hand / costs on the Items pages, and the Excel import engine made price-list-optional
so the same wizard imports stock lines (Unit Price column = unit cost).

Errors 62xxx: 62000 `VALIDATION` (line messages start with "Line N:"), 62004 `CONCURRENCY`, 62005 `NOT_DRAFT`,
62006 `NOT_FOUND`, 62007 `INSUFFICIENT_STOCK`, 62008 `MASTER_INACTIVE`, 62009 `NO_LINES`, 62010 `INVALID_STATUS`.
Permissions (module Inventory): `inventory.stockin.view/create/post/cancel/delete`, `inventory.stockout.*`,
`inventory.documenttypes.manage` (Configuration).

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern: Dapper repositories over stored procedures (SqlErrors -> BusinessRuleException), services
returning Result with codes, controllers with [HasPermission], PermissionCatalog, Schema.sql embedded. ClosedXML
is already referenced (import engine). 0 warnings.

Feature: Inventory In / Inventory Out documents + the stock ledger - the first document family; its API shape is
the template for Purchase and Sales later. Script already written:
D:\VSProjects\Inventory_Shipment\Database\15_Inventory_StockDocuments.sql - read its header. Key objects:
- inventory.DocumentTypes (+ usp_DocumentType_List, usp_DocumentType_NextNumber), inventory.StockReasons
  (+ usp_StockReason_Lookup @Direction), inventory.StockMovements + fn_StockOnHand(@ItemId, @WarehouseId) +
  fn_AverageCost + vw_StockBalance.
- inventory.StockDocuments / StockDocumentLines / StockDocumentFiles / StockDocumentAudit, table type
  inventory.tvp_StockDocumentLine (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitCost, Notes).
- usp_StockDocument_Search(@DocumentTypeCode INV_IN|INV_OUT|NULL, @Search, @BranchId, @WarehouseId, @Status 1|2|3,
  @DateFrom, @DateTo, @SortColumn DocumentNumber|DocumentDate|BranchName|WarehouseName|Status|TotalCost|CreatedAtUtc,
  @SortDirection, @PageNumber, @PageSize) -> rows + TotalCount.
- usp_StockDocument_Get(@Id) -> 4 result sets: header (with type code/name/StockDirection/NumberOnPost, names,
  totals, posted/cancelled info), lines (with item/unit/warehouse names, PackingFormula, QuantityBase, LineTotal,
  OnHandBase), files metadata, audit trail.
- usp_StockDocument_Save(@Id NULL=create, @DocumentTypeCode, @DocumentDate, @BranchId, @WarehouseId, @ReasonId,
  @ReferenceNo, @Notes, @Lines TVP, @RowVersion, @UserId, @NewId OUT) - full replace of the lines; drafts only.
- usp_StockDocument_Post(@Id, @RowVersion, @UserId) -> returns DocumentNumber; usp_StockDocument_Cancel(@Id,
  @Reason, @RowVersion, @UserId); usp_StockDocument_Delete(@Id, @UserId) (drafts only);
  usp_StockDocumentFile_Add/_Get/_Delete.
- inventory.usp_Item_Search / usp_Item_Get were RE-CREATED: OnHand, LastCost, AverageCost now come from the
  ledger (the DTO mapping does not change; the Items pages start showing real values; sort column "OnHand" added).
- sales.usp_InvoiceImport_Validate now accepts @PriceListId NULL (stock documents: no pricing, UnitPrice = cost).
THROW mapping: 62000 Validation VALIDATION; 62004 Conflict CONCURRENCY; 62005 Conflict NOT_DRAFT; 62006 NotFound;
62007 Conflict INSUFFICIENT_STOCK; 62008 Validation MASTER_INACTIVE; 62009 Validation NO_LINES; 62010 Conflict
INVALID_STATUS. 61008 (import header) stays MASTER_INACTIVE.

TASK
1. Run the script (sqlcmd -S . -E -d Inventory_Shipment -i "...\Database\15_Inventory_StockDocuments.sql"), show
   its output, append it to Repository\Database\Schema.sql under "-- ===== 15: Inventory documents + stock
   ledger =====" (no USE batch, no final report batch; keep the guarded CREATE TYPE and the MERGE seeds).
2. Model (Entities + DTOs/Inventory/):
   - DocumentTypeDto (id, code, name, family, stockDirection, numberPrefix, nextNumber, numberLength,
     numberOnPost, requiresReason, isActive), StockReasonDto.
   - StockDocumentListDto (id, documentTypeCode, documentTypeName, stockDirection, documentNumber (null for
     unnumbered drafts), documentDate, branchName, warehouseName, reasonName, referenceNo, currencyCode, status
     as string Draft|Posted|Cancelled, totalItems, totalQuantity, totalCost, postedAtUtc, postedByName,
     createdAtUtc, createdByName, rowVersion).
   - StockDocumentDto (header fields incl. ids + names + canEdit/canPost/canCancel/canDelete computed from
     status, lines[] StockDocumentLineDto (id, lineNo, itemId, itemCode, itemName, itemUnitId, unitTypeName,
     skuCode, barcode, packingFormula, warehouseId, warehouseCode, warehouseName, expiryDate, quantity,
     quantityBase, unitCost, lineTotal, notes, onHandBase), files[] (id, fileName, contentType, sizeBytes,
     createdAtUtc, createdByName), audit[] (action, details, userName, atUtc)).
   - SaveStockDocumentRequest (DocumentTypeCode [Required] "INV_IN"|"INV_OUT", DocumentDate [Required] DateOnly,
     BranchId, WarehouseId, ReasonId?, ReferenceNo [StringLength(100)], Notes [StringLength(1000)], Lines[] of
     SaveStockDocumentLineRequest (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate?, Quantity [Range(1,..)],
     UnitCost [Range(0,..)]?, Notes [StringLength(300)]), RowVersion?).
   - CancelStockDocumentRequest (Reason [Required, StringLength(300)], RowVersion?), PostStockDocumentRequest
     (RowVersion?), StockDocumentQuery (DocumentTypeCode?, Search, BranchId?, WarehouseId?, Status?, DateFrom?,
     DateTo?, SortBy = DocumentDate, SortDir = desc, Page, PageSize).
   - PermissionCatalog: inventory.stockin.view/create/post/cancel/delete (700-740), inventory.stockout.* (760-800),
     module "Inventory"; inventory.documenttypes.manage (module "Configuration", 900).
3. Repository IStockDocumentRepository (Search, Get via QueryMultiple, Save with the TVP, Post, Cancel, Delete,
   file Add/Get/Delete, DocumentTypes list, StockReasons lookup); register.
4. Service IStockDocumentService: SaveDraftAsync, PostAsync (optionally SaveAndPost = save then post in sequence
   - the controller does two calls), CancelAsync, DeleteAsync, GetAsync, SearchAsync, files, ExportAsync(id) ->
   xlsx via ClosedXML (header block + lines + totals). Permission for the action depends on the document type:
   INV_IN -> inventory.stockin.*, INV_OUT -> inventory.stockout.* (check in the service with the user's
   permissions since one controller serves both types; return Forbidden otherwise).
5. API StockDocumentsController route api/inventory/stock-documents:
     GET  ?query (documentTypeCode required)         [Authorize + service permission check] -> PagedResult
     GET  {id}                                        -> StockDocumentDto
     POST                                             SaveStockDocumentRequest -> 201 StockDocumentDto (draft)
     PUT  {id}                                        SaveStockDocumentRequest -> 200 StockDocumentDto (draft)
     POST {id}/post                                   PostStockDocumentRequest -> 200 StockDocumentDto (posted, with number)
     POST {id}/cancel                                 CancelStockDocumentRequest -> 200 StockDocumentDto
     DELETE {id}                                      -> 204 (drafts)
     GET  {id}/export                                 -> xlsx
     POST {id}/files (multipart, <= 10 MB, pdf/xlsx/docx/images) -> 201; GET {id}/files/{fileId}; DELETE {id}/files/{fileId}
     GET  api/inventory/document-types                [Authorize] -> DocumentTypeDto[]
     GET  api/inventory/stock-reasons?direction=1|-1  [Authorize] -> StockReasonDto[]
     GET  api/inventory/stock/on-hand?itemId=&warehouseId= [Authorize] -> { onHandBase } (for the line grid)
   Import: extend the existing invoice-import validate endpoint so priceListId is OPTIONAL (null = stock mode,
   no pricing) and pass NULL to the proc.
6. Build 0 warnings; API starts with "Database schema verified"; Scalar shows the endpoints.

VERIFY (token admin / Admin@12345) with curl, show output:
  a. GET document-types -> 8 rows (INV_IN numberOnPost false, SINV true); stock-reasons?direction=1 -> 5 In reasons.
  b. POST an INV_IN draft (main branch/warehouse, reason OPENING, 2 lines: TVS-AP160 PC qty 3 cost 2100, a
     second item or the same item in another active warehouse of the branch) -> 201 with documentNumber
     "IN-000001", status Draft, totals (items 2, quantity, cost).
  c. PUT the same draft changing a quantity -> 200; posted-only checks: POST {id}/post -> 200 status Posted;
     SELECT from inventory.StockMovements shows +3 (base units) with UnitCostBase 2100; GET api/inventory/items/{id}
     now returns onHand 3, lastCost 2100, averageCost 2100.
  d. PUT the posted document -> 409 NOT_DRAFT; DELETE it -> 409 NOT_DRAFT.
  e. POST an INV_OUT draft for the same item qty 5 -> 201 (unit cost auto = average 2100); POST {id}/post ->
     409 INSUFFICIENT_STOCK with the "available 3, required 5" message; change to qty 2 -> post -> 200; on-hand 1.
  f. POST {inId}/cancel with reason "test" -> 409 INSUFFICIENT_STOCK (only 1 left of the 3 added); cancel the
     OUT document instead -> 200 status Cancelled, reversal movement written, on-hand back to 3; now cancel the
     IN -> 200, on-hand 0.
  g. Upload a PDF attachment to a posted document -> 201, download it, delete it; audit trail lists Created /
     Updated / Posted / Cancelled / FileAdded / FileDeleted with user names.
  h. Import validate with priceListId omitted and a row "TVS-AP160 | PC | | 4 | 2050" -> Valid, unitPrice 2050,
     priceSource Manual; a row without price -> Valid with unitPrice null.
  i. A user with inventory.stockin.view only -> 403 on POST; the export endpoint returns an xlsx.
Report: script output, files changed, every verification result.
```

## Prompt B — Frontend (Inventory In / Out documents)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared
ui components, auto-apply filters, responsive at 390/768/1024/1440). Frontend only. Backend exists under
api/inventory/stock-documents (search/get/create/update/post/cancel/delete/export/files), api/inventory/
document-types, api/inventory/stock-reasons?direction=, api/inventory/stock/on-hand?itemId=&warehouseId=, plus
lookups: branches/lookup, warehouses/lookup?branchId=, api/inventory/items/lookup?search=, items/{id}
(units), and the import wizard endpoints (api/sales/invoice-import/validate now accepts NO priceListId = stock
mode). Error codes: VALIDATION (line messages start with "Line N:"), CONCURRENCY, NOT_DRAFT, NOT_FOUND,
INSUFFICIENT_STOCK, MASTER_INACTIVE, NO_LINES, INVALID_STATUS. Dev: npm run dev, admin / Admin@12345.

Feature: Inventory In (and, with the same screens, Inventory Out) - the FIRST DOCUMENT FAMILY. Build it as a
reusable document-page skeleton because Purchase and Sales documents will reuse the layout: header card,
Quick Item Search, editable lines grid, attachments, summary/totals, action bar. Visual reference: the customer's
"New Invoice" figure (header fields in a 5-column responsive grid, quick search with barcode icon, lines table
with inline inputs, totals card bottom-right, action buttons top-right: Attachments (n) / Import from File /
Save Draft / Cancel / Save & Post).

TASK
1. src/api/inventory/stockDocuments.ts (+ documentTypes, stockReasons, stock on-hand); types StockDocument,
   StockDocumentLine, etc.
2. Navigation (section Inventory): "Inventory In" (inventory.stockin.view) and "Inventory Out"
   (inventory.stockout.view) after Item Definition; routes /inventory/stock-in, /inventory/stock-in/new,
   /inventory/stock-in/:id and the same under /inventory/stock-out. One page component parameterised by
   documentTypeCode ('INV_IN' | 'INV_OUT'); labels/permissions/colours switch with it (In = green accents,
   Out = orange).
3. LIST page (per type): FilterBar (search number/reference, Branch, Warehouse (filtered by branch), Status
   All/Draft/Posted/Cancelled, Date from/to, Clear Filters); DataTable server-side: #, Document No. (or a grey
   "DRAFT" badge when null), Date, Branch, Warehouse, Reason, Reference, Items, Quantity (base units), Total Cost
   (USD), Status badge (Draft grey, Posted green, Cancelled red), RowActions: View, Edit (drafts, create perm),
   Post (drafts, post perm, confirm), Cancel (posted, cancel perm, dialog asking the reason), Delete (drafts,
   delete perm, danger confirm). "+ New Inventory In" button.
4. DOCUMENT page (/new, /:id) - modes: create / edit (draft) / view (posted or cancelled = read-only with a
   status banner showing number, posted by/at or cancelled by/at + reason).
   Header card "Document Information": Document No. (read-only; "Assigned on save" for new when the type
   numbers at draft, "Assigned on posting" when numberOnPost), Branch* (Select), Default Warehouse* (Select
   filtered by branch; changing the branch resets it), Document Date* (DateInput, default today, max today),
   Reason* (Select from stock-reasons?direction=, required when the type requires it), Reference No. (TextInput,
   e.g. delivery note / count sheet), Currency (read-only "USD - US Dollar", base), Notes (Textarea).
   Quick Item Search: a TextInput with a barcode icon, placeholder "Scan barcode or enter item code and press
   Enter"; on Enter call items/lookup?search=<text>: exact code or barcode match -> add a line immediately
   (unit = barcode's unit, else base unit; warehouse = header default; qty 1; cost = last cost from the item
   details when available, else 0); several matches -> a small popover list to pick; none -> notify.error "Item
   <text> not found". If a line with the same item + unit + warehouse already exists, increase its quantity by 1
   instead of adding a duplicate. Keep focus in the search box after each scan.
   Lines grid ("Document Details"): inline-editable table built with the shared DataTable or a plain Mantine
   Table (no paging): #, Item Code (searchable Select using items/lookup, shows code + name, name under it),
   Item Name (read-only), Unit (Select from that item's units, shows "PC" / "Box (x12)"), Warehouse (Select,
   warehouses of the branch, defaults from header), Expiry Date (DateInput, optional), On Hand (read-only, from
   stock/on-hand for item+warehouse, refreshed when either changes; for INV_OUT show it red when qty x formula
   > on hand), Qty (NumberInput min 1, integer), Unit Cost (NumberInput, 2 decimals, USD; read-only for INV_OUT
   with tooltip "Average cost is applied automatically"), Amount (read-only = qty x cost), Notes (TextInput),
   Delete icon. Row footer "+ Click to add an item..." adds an empty line. Buttons above the grid: "+ Add Item",
   "Clear All Lines" (confirm), "Export to Excel" (saved documents; calls {id}/export), "Import from File"
   (opens the existing ImportInvoiceItemsWizard in stock mode: header = { branchId, warehouseId, priceListId:
   null, currencyCode: 'USD', decimalPlaces: 2 }, price column labelled "Unit Cost"; imported lines are
   appended). Keyboard: Enter in Qty moves to the next row's Item; Tab order left-to-right.
   Attachments: "Attachments (n)" button in the action bar opens a drawer with the list (name, size, date, by,
   download, delete) + Dropzone (pdf/xlsx/docx/images <= 10 MB). Available once the document is saved (on a new
   document show "Save the draft first to attach files").
   Summary card (bottom-right): Total Items, Total Quantity (base units), Total Cost (USD); a left card with the
   audit trail (last 5 entries, "show all" expands).
   Action bar (top-right, sticky on scroll and also visible at the bottom on mobile): Attachments (n), Import
   from File, Save Draft, Cancel (back to list with unsaved-changes confirm), Save & Post (primary; = save then
   post; confirm dialog "Post IN-000012? Stock will be updated and the document becomes read-only."). In view
   mode: Export to Excel, Cancel Document (posted, cancel perm, reason dialog), Back.
   Validation: client-side before save (branch, warehouse, date, reason if required, at least one line, each
   line item/unit/warehouse/qty >= 1, cost >= 0); API VALIDATION messages starting with "Line N:" are shown on
   that line (highlight row + tooltip) and as a notify; INSUFFICIENT_STOCK / NO_LINES / NOT_DRAFT / CONCURRENCY
   shown as notify with the API message (concurrency also reloads).
   Totals recalculate on every change; unsaved-changes guard on navigation; posted/cancelled documents are fully
   read-only (inputs replaced by text).
5. Items page tweak: the On Hand column/card now shows real numbers (no "coming soon" hints anymore); add
   "On Hand" as a sortable column.
6. docs/frontend-conventions.md: add "Document pages" section describing the reusable skeleton (components:
   DocumentHeaderCard, QuickItemSearch, DocumentLinesGrid, DocumentSummary, DocumentActionBar, AttachmentsDrawer,
   AuditTrail) so Purchase/Sales reuse them.
7. Quality: typecheck / lint / build clean; all breakpoints (lines table scrolls horizontally on mobile, action
   bar collapses into a menu below 768 px); permission gating (view-only users see read-only documents, no
   buttons).

VERIFY (API running) with screenshots at 1440 and 390:
  a. New Inventory In: header defaults (today, main branch, its main warehouse), reason list shows In reasons only;
     scan/enter "TVS-AP160" + Enter adds the line with unit PC and cost = last cost; Enter again increments qty.
  b. Add a line via "+ Add Item" choosing item/unit/warehouse; Amount and totals update live; Save Draft -> number
     IN-0000xx appears, audit shows Created; edit qty, Save Draft -> Updated.
  c. Save & Post -> confirm -> status Posted banner, inputs read-only; the Items page shows the new On Hand;
     Export to Excel downloads the file; Attachments drawer uploads a PDF and lists it.
  d. Inventory Out: On Hand column shows stock; entering qty above stock turns it red; Save & Post with too much
     -> INSUFFICIENT_STOCK message from the API; correct qty -> posted; unit cost column read-only with the
     average cost.
  e. Cancel the posted Out document (reason required) -> Cancelled badge, On Hand restored; cancelling the In
     while its stock was consumed shows the API's "Cannot cancel" message.
  f. Import from File on a draft In (stock mode): the wizard labels the price column "Unit Cost", validates
     without price-list errors, imports lines into the grid.
  g. List filters auto-apply; DRAFT badge for unnumbered drafts (set INV_IN numberOnPost=1 in the DB to see it,
     then set it back); a view-only user sees everything read-only.
Report: files added/changed, navigation changes, every verification result.
```
