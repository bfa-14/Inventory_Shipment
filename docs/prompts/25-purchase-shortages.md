# Batch 4 — Shortages page + Purchase Order / Purchase Invoice / Purchase Return

Point **10**. SQL: `21_Purchase_Documents.sql` (already run with batch 2). Requires batches 1–3 applied (skeleton,
bulk actions, import per warehouse, type configuration, sales invoice as the reference for a priced document).

Flow: **Shortages** (general formula, per item + warehouse) → select rows → **Create Purchase Order** (one draft PO
per supplier) → post PO → **Create Purchase Invoice** from the PO (remaining quantities, partial receipts, PO
auto-closes when fully received) → post PINV (stock +, cost in supplier currency converted to USD, moving average,
last cost / last supplier) → **Create Purchase Return** from a posted PINV → post PRET (stock −). All three can also
be created from scratch and imported from Excel (common template, one document per warehouse).

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern as in the stock / sales documents (repository over procedures + TVP, service with per-type
permission checks, controller, export, bulk helper, GroupLinesByWarehouse helper).

Script already written and in Schema.sql: D:\VSProjects\Inventory_Shipment\Database\21_Purchase_Documents.sql -
read its header. Objects (schema purchase): PurchaseDocuments / PurchaseDocumentLines (+ ReceivedQuantityBase,
ReturnedQuantityBase, UnitCostBase) / Files / Audit; tvp_PurchaseDocumentLine (LineNumber, ItemId, ItemUnitId,
WarehouseId, ExpiryDate, Quantity, UnitPrice NULL = item last cost converted, DiscountPercent NULL, ImportRowNumber,
Notes, SourceLineId); usp_PurchaseDocument_Search(@DocumentTypeCode PO|PINV|PRET|NULL, @Search, @BranchId,
@WarehouseId, @SupplierId, @Status 1 Draft|2 Posted|3 Cancelled|4 Closed, @DateFrom, @DateTo, sort
DocumentNumber|DocumentDate|SupplierName|Status|TotalAmount|CreatedAtUtc, page) (+ ReceivedPercent for POs);
usp_PurchaseDocument_Get(@Id) -> FIVE result sets: header (supplier, currency code/symbol/decimals/IsBase,
RateType, ExchangeRate, BaseCurrencyCode, SourceDocumentId/Number/TypeCode, totals, posted/cancelled/closed info),
lines (+ RemainingBase, OnHandBase, ItemLastCost, ItemAverageCost), files, audit, linked documents
(Relation Source|Child, Id, DocumentTypeCode/Name, DocumentNumber, DocumentDate, Status, TotalAmount, CurrencyCode);
usp_PurchaseDocument_Save(@Id, @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId,
@SupplierId, @CurrencyId NULL = supplier default/base, @RateType, @ExchangeRate NULL = auto, @SupplierReference,
@Notes, @Lines, @MaxDiscountPercent, @SourceDocumentId, @RowVersion, @UserId, @NewId OUT) - when updating a draft
created from a source, pass the same @SourceDocumentId; usp_PurchaseDocument_Post / _Cancel(@Reason) /
_Close(@Reason, PO only) / _Delete; usp_PurchaseDocument_CreateFromSource(@SourceId, @TargetTypeCode PINV|PRET,
@DocumentDate, @UserId, @NewId OUT) -> draft with the remaining quantities; usp_PurchaseDocumentFile_*;
masterdata.usp_ExchangeRate_Resolve(@CurrencyId, @RateType, @AsOfDate); inventory.usp_Shortage_Report(@BranchId,
@WarehouseId, @ItemFamilyId, @BrandId, @SupplierId, @Search, @OnlyShortages, @DaysForAverage).
Errors 65xxx -> codes: 65000 VALIDATION, 65004 CONCURRENCY, 65005 NOT_DRAFT, 65006 NOT_FOUND, 65007
INSUFFICIENT_STOCK, 65008 MASTER_INACTIVE, 65009 NO_LINES, 65010 INVALID_STATUS, 65011 SOURCE_INVALID (409).
Permissions: purchase.orders.* (1000-1040), purchase.invoices.* (1060-1100), purchase.returns.* (1120-1160)
module Purchase; inventory.shortages.view (950) module Inventory.

TASK
1. Model (DTOs/Purchase/): PurchaseDocumentListDto, PurchaseDocumentDto (header + lines[] + files[] + audit[] +
   linked[] + can* flags: canEdit (draft), canPost (draft), canCancel (posted/closed without posted children),
   canClose (PO posted), canDelete (draft), canCreateInvoice (PO posted with remaining), canCreateReturn (PINV
   posted with remaining)), SavePurchaseDocumentRequest (DocumentTypeCode PO|PINV|PRET, DocumentDate, ExpectedDate?,
   BranchId, WarehouseId, SupplierId, CurrencyId?, RateType = 1, ExchangeRate?, SupplierReference?, Notes?,
   SourceDocumentId?, Lines[] { LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate?, Quantity, UnitPrice?,
   DiscountPercent?, ImportRowNumber?, Notes?, SourceLineId? }, RowVersion?), Post/Cancel/Close requests,
   PurchaseDocumentQuery, CreateFromSourceRequest (documentDate?), ShortageRowDto (all columns of the report),
   ShortageQuery, CreatePurchaseOrdersFromShortagesRequest { documentDate, expectedDate?, lines[] { itemId,
   warehouseId, supplierId, itemUnitId, quantity } } -> result { orders[] { id, documentNumber (null), supplierName,
   warehouseName, lineCount } }.
2. Repository IPurchaseDocumentRepository (Search, Get via QueryMultiple x5, Save, Post, Cancel, Close, Delete,
   CreateFromSource, files, ResolveRate) + IShortageRepository (Report).
3. Service IPurchaseDocumentService: permission set chosen by type (PO -> purchase.orders.*, PINV ->
   purchase.invoices.*, PRET -> purchase.returns.*; checked in the service like the stock documents), Save
   (MaxDiscountPercent from "Purchase:MaxDiscountPercent", default 100), Post, Cancel, Close, Delete, Get, Search,
   CreateFromSource (the caller needs create on the TARGET type), Export (xlsx with supplier, currency, rate, lines,
   totals + base), files, bulk post/delete (shared helper), ImportCreate (GroupLinesByWarehouse: one document per
   warehouse; postImmediately). IShortageService: Report; CreateOrdersAsync: group the lines by supplier AND
   warehouse (branch = the warehouse's branch), one draft PO per group via Save (UnitPrice null = last cost),
   returns the created orders.
4. API:
   PurchaseDocumentsController route api/purchase/documents (documentTypeCode in the query / body, like stock
   documents): GET ?query, GET {id}, POST, PUT {id}, POST {id}/post, POST {id}/cancel, POST {id}/close, DELETE {id},
   GET {id}/export, files endpoints, POST {id}/create-invoice (PO -> PINV draft) and POST {id}/create-return
   (PINV -> PRET draft) both returning the new PurchaseDocumentDto, POST bulk-post, POST bulk-delete,
   POST import-create, GET api/purchase/rate?currencyId=&rateType=&date= [Authorize].
   ShortagesController route api/inventory/shortages: GET ?branchId&warehouseId&itemFamilyId&brandId&supplierId
   &search&onlyShortages=true&daysForAverage=30 [inventory.shortages.view] -> ShortageRowDto[] (not paged);
   GET export (same filters) -> xlsx; POST create-orders [purchase.orders.create] -> created orders.
   Import validate for purchase types: documentTypeCode PO/PINV/PRET, priceListId omitted (cost mode); the wizard
   rows' unitPrice = supplier cost in the document currency.
5. PermissionCatalog: the 16 codes above. Build 0 warnings; "Database schema verified".

VERIFY (token admin / Admin@12345) with curl, show output. Preparation: supplier SUP-0001 with DefaultCurrencyId
= a CDF (or EUR) currency that has an official rate; item TVS-AP160 with default supplier SUP-0001, min 5, max 20.
  a. GET shortages?onlyShortages=false -> TVS-AP160 row per warehouse with onHandBase, incomingBase 0,
     shortageBase / suggestedQty consistent with min/max; export -> xlsx.
  b. POST shortages/create-orders with 2 lines (same supplier, WH-001 and WH-002) -> 2 draft POs; GET one ->
     currency = supplier currency, rate auto, line price = last cost converted (0 when none).
  c. PUT a line price 250000 CDF, POST {id}/post -> PO-<BRANCH>-000001 status Posted (no movements);
     shortages now show incomingBase > 0 for that warehouse.
  d. POST {poId}/create-invoice -> PINV draft with the remaining quantity and SourceDocumentId; POST post ->
     PINV-<BRANCH>-000001, movements + with UnitCostBase = 250000 / packing / rate (USD), item averageCost /
     lastCost / lastSupplier updated, PO status Closed (Fully received), PO line receivedQuantityBase = qty.
  e. Partial: new PO of 10, invoice 4 -> PO stays Posted with remaining 6; second invoice of 7 -> 409
     SOURCE_INVALID "only 6 remain"; invoice 6 -> PO Closed.
  f. POST {pinvId}/create-return -> PRET draft; post -> movements -, cost = invoice cost; cancel the PRET ->
     reversal. Cancel the PINV while the PRET is posted -> 409 SOURCE_INVALID; cancel the PRET first, then the PINV
     -> PO re-opened, received quantities back.
  g. bulk-post of 2 PO drafts -> both posted; import-create for PINV with 2 warehouses -> 2 invoices.
  h. A user with purchase.orders.view only -> 403 on POST.
Report: files changed, every verification result.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared ui
components, document-page skeleton used by Inventory In and Sales Invoice, DocumentListPage bulk actions, import
wizard with one-document-per-warehouse, useDocumentTypes()). Frontend only. Backend: api/purchase/documents
(list/get/create/update/post/cancel/close/delete/export/files/create-invoice/create-return/bulk-post/bulk-delete/
import-create), api/purchase/rate, api/inventory/shortages (list/export/create-orders), lookups (branches,
warehouses, parties?type=Supplier, currencies/lookup, items/lookup, items/{id}, item-families, brands).
Error codes: VALIDATION ("Line N: ..."), CONCURRENCY, NOT_DRAFT, NOT_FOUND, INSUFFICIENT_STOCK, MASTER_INACTIVE,
NO_LINES, INVALID_STATUS, SOURCE_INVALID. Permissions: purchase.orders.*, purchase.invoices.*, purchase.returns.*,
inventory.shortages.view, sales.invoices.import (wizard). Dev: npm run dev, admin / Admin@12345.

TASK
1. Navigation: new section PURCHASE: "Purchase Orders" (/purchase/orders), "Purchase Invoices"
   (/purchase/invoices), "Purchase Returns" (/purchase/returns); INVENTORY: "Shortages" (/inventory/shortages,
   inventory.shortages.view) replacing the "coming soon" entry. One page component parameterised by
   documentTypeCode ('PO' | 'PINV' | 'PRET'); labels / permissions / colours switch (PO blue, PINV green, PRET
   orange).
2. LIST pages (DocumentListPage): FilterBar (search number/supplier reference/supplier, Branch, Supplier
   (searchable), Status All/Draft/Posted/Cancelled/Closed, Date from/to); columns #, Document No. (DRAFT badge),
   Date, Expected/Due, Supplier, Branch, Warehouse, Source (linked number, clickable), Received % (PO: progress
   bar), Items, Total (currency), Status badge (Closed = teal), RowActions View / Edit / Post / Cancel / Close (PO)
   / Delete / "Create invoice" (PO posted with remaining) / "Create return" (PINV posted); bulk Post / Delete;
   "+ New ...".
3. DOCUMENT page (skeleton): header "Order / Invoice / Return Information": Document No., Date*, Expected date
   (PO) / Due date (PINV), Branch*, Warehouse*, Supplier* (searchable; selecting sets Currency to the supplier's
   default currency when the user has not changed it), Currency (Select from currencies/lookup; default supplier
   currency else USD), Rate Type + Exchange Rate (auto via api/purchase/rate; "1 (base currency)" for USD; manual
   entry with warning when none), Supplier Reference (supplier's order / invoice no.), Notes; a "Source" chip
   (linked document number, click opens it) when the document was created from another one.
   Lines (pricing from the type config: Cost, editable): Quick Item Search + "+ Add Item" (unit = purchase unit
   else base; price = item last cost converted to the document currency = lastCost x packingFormula x rate; PRET
   from scratch: price = last cost as well), Item Code (link), Item Name, Unit, On Hand, Qty (for documents created
   from a source: max = remaining, shown as "Remaining: n" under the input), Unit Price (document currency),
   Disc %, Line Total, Notes, Delete; "Import from Excel" (cost mode, one document per warehouse), "Clear All
   Lines", "Export to Excel". Summary: Total Items, Total Quantity, Subtotal, Discount, Grand Total (currency) +
   "≈ ... USD at <rate>"; "Linked documents" card (source + children with status badges, clickable); audit card.
   Action bar: Attachments, Import from Excel, Save Draft, Cancel, Save & Post (confirm text per type: PO "Confirm
   this order?", PINV "Post this invoice? Stock will be added to <warehouse> and item costs updated.", PRET "Post
   this return? Stock will be removed from <warehouse>."). View mode: Export, "Create Purchase Invoice" (PO
   posted/remaining), "Create Purchase Return" (PINV posted), "Close Order" (PO posted, reason optional), Cancel
   Document (reason), Back. Errors as the other pages; SOURCE_INVALID messages ("Line N: ... only 6 remain") on the
   line + notify.
4. SHORTAGES page (/inventory/shortages): FilterBar (Branch, Warehouse, Family (tree select), Brand, Supplier,
   search, toggle "Only shortages" default on, "Average over" 30/60/90 days); summary cards (Items short, Total
   suggested cost = SUM(suggestedBase x lastCost) USD, Warehouses affected); DataTable (client-side paging/sort):
   selection column, Item (code link + name), Warehouse, On Hand, Incoming (open PO), Available, Min, Max, Shortage,
   Suggested (qty + purchase unit, e.g. "3 Box"), Avg daily sales, Days of cover (red < lead time), Supplier
   (name + "default" badge; empty -> warning icon), Last cost, Lead time. Row colour: red when On Hand = 0, orange
   when short. "Export to Excel". Selection toolbar: "Create Purchase Order (n)" -> modal: table of the selected
   rows with editable Quantity (default = suggested, in the purchase unit) and Supplier (Select, required; rows
   without one must be filled), Order date (today) and Expected date; grouping preview "2 orders will be created:
   SUP-0001 / WH-001 (3 lines), SUP-0002 / WH-002 (1 line)"; Create -> POST create-orders -> success list with
   links to the new draft POs; the report reloads (incoming unchanged until the POs are posted - say so in an info
   line).
5. docs/frontend-conventions.md: "Purchase documents" and "Shortages -> PO" sections.
6. Quality: typecheck / lint / build clean; all breakpoints; permission gating per type.

VERIFY (API running) with screenshots at 1440 and 390:
  a. Shortages: TVS-AP160 appears short after its min is set above the on-hand; select it -> Create Purchase
     Order -> draft PO opens/lists; post the PO -> Shortages shows Incoming and the row leaves the "short" state
     when Available >= Min.
  b. PO page: supplier sets currency CDF and rate; line price defaults to last cost converted; Save & Post ->
     PO-<BRANCH>-000001; "Create Purchase Invoice" -> PINV draft with remaining quantities and the Source chip;
     post -> Items page cost/on-hand updated; PO shows Received 100 % and status Closed.
  c. Partial receipt: PO of 10, invoice 4 -> PO Posted with Received 40 %; second invoice limited to 6 (typing 7
     shows the API's SOURCE_INVALID message on the line).
  d. PINV view -> "Create Purchase Return" -> PRET draft -> post -> On Hand down; cancel PRET -> restored.
  e. Import from Excel on a PINV with rows for 2 warehouses -> 2 invoices created; bulk post 2 PO drafts.
  f. A user with only purchase.orders.view sees read-only orders and no Purchase Invoices menu.
Report: files added/changed, navigation changes, every verification result.
```
