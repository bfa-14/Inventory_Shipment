# Sales Invoice (lines from Excel only) — SQL + VS Code prompts

Run order: `Database\17_Sales_Documents.sql` in SSMS (needs 08, 12, 13, 14, 15) → Prompt A (API) → Prompt B (Web).

Scope of this step: the **Sales Invoice** page whose lines come **only from the Excel import wizard** (no manual
item entry yet — quick search / "+ Add Item" arrive in a later step). The SQL already covers the whole Sales
family (Sales Order / Invoice / Return share `sales.SalesDocuments` + `sales.SalesDocumentLines`, discriminated by
`inventory.DocumentTypes`), but only `SINV` is exposed now.

Rules implemented in SQL: client = party flagged Client; salesman optional; invoice currency = price list
currency; exchange rate auto from Master Data (Official by default, Non-official / Market selectable, editable);
line price = price list price unless the user holds `sales.invoices.priceoverride`; discount % limited by
`Sales:MaxDiscountPercent`; Draft → Posted (stock removed, COGS snapshot, number `INV-000001` assigned on
posting) → Cancelled (reversal). Errors 64xxx: 64000 `VALIDATION` ("Line N: …"), 64004 `CONCURRENCY`, 64005
`NOT_DRAFT`, 64006 `NOT_FOUND`, 64007 `INSUFFICIENT_STOCK`, 64008 `MASTER_INACTIVE` (also "no exchange rate"),
64009 `NO_LINES`, 64010 `INVALID_STATUS`, 64011 `NO_PRICE`. Permissions (module Sales): `sales.invoices.view /
create / post / cancel / delete` (620–660) + existing `sales.invoices.import` (600) and `priceoverride` (610).
Test file for the wizard: `docs\samples\Import_Items_Sample.xlsx` (TVS-AP160 / WH-001, price list Retail USD).

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern: Dapper repositories over stored procedures (SqlErrors -> BusinessRuleException), services
returning Result with codes, controllers with [HasPermission], PermissionCatalog, Schema.sql embedded, ClosedXML
referenced. The Inventory In/Out implementation (StockDocuments*: repository with QueryMultiple + TVP, service
with per-type permission checks, controller, export) is the TEMPLATE for this task - mirror it, do not reinvent.

Feature: SALES INVOICE documents (family Sales, type SINV). Script already written:
D:\VSProjects\Inventory_Shipment\Database\17_Sales_Documents.sql - read its header. Key objects (schema sales):
- SalesDocuments / SalesDocumentLines / SalesDocumentFiles / SalesDocumentAudit; table type
  sales.tvp_SalesDocumentLine (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice NULL,
  DiscountPercent NULL, ImportRowNumber NULL, Notes).
- usp_SalesDocument_Search(@DocumentTypeCode 'SINV', @Search, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
  @Status 1|2|3, @DateFrom, @DateTo, @SortColumn DocumentNumber|DocumentDate|ClientName|Status|TotalAmount|
  CreatedAtUtc, @SortDirection, @PageNumber, @PageSize) -> rows + TotalCount.
- usp_SalesDocument_Get(@Id) -> 4 result sets: header (type, number, dates, branch/warehouse, client code/name/
  phone/email/address, salesman, price list, currency code/symbol/decimals/IsBaseCurrency, RateType, ExchangeRate,
  BaseCurrencyCode, totals: TotalItems, TotalQuantity, Subtotal, TotalDiscount, TotalAmount, TotalAmountBase,
  TotalCostBase, posted/cancelled info, RowVersion), lines (item/unit/warehouse names, PackingFormula,
  QuantityBase, UnitPrice, DiscountPercent, LineDiscount, LineTotal, PriceSource, UnitCostBase, ImportRowNumber,
  OnHandBase, SystemPrice), files metadata, audit.
- usp_SalesDocument_Save(@Id NULL=create, @DocumentTypeCode 'SINV', @DocumentDate, @DueDate, @BranchId,
  @WarehouseId, @ClientId, @SalesmanId, @PriceListId, @RateType 1|2|3, @ExchangeRate NULL=auto, @ReferenceNo,
  @Notes, @Lines TVP, @AllowPriceOverride, @MaxDiscountPercent, @DraftReference, @RowVersion, @UserId, @NewId OUT)
  - full replace of the lines; drafts only; prices re-resolved from the price list unless override allowed.
- usp_SalesDocument_Post(@Id, @RowVersion, @UserId) -> DocumentNumber; usp_SalesDocument_Cancel(@Id, @Reason,
  @RowVersion, @UserId); usp_SalesDocument_Delete(@Id, @UserId); usp_SalesDocumentFile_Add/_Get/_Delete;
  usp_SalesDocument_ResolveRate(@PriceListId, @RateType, @AsOfDate) -> 1 row (CurrencyCode, Symbol,
  DecimalPlaces, IsBaseCurrency, RateType, Rate (NULL when none), RateDate, BaseCurrencyCode).
- sales.usp_InvoiceImport_Log RE-CREATED: @PriceListId may be NULL, @InvoiceId optional but must exist.
THROW mapping: 64000 Validation VALIDATION; 64004 Conflict CONCURRENCY; 64005 Conflict NOT_DRAFT; 64006 NotFound;
64007 Conflict INSUFFICIENT_STOCK; 64008 Validation MASTER_INACTIVE; 64009 Validation NO_LINES; 64010 Conflict
INVALID_STATUS; 64011 Validation NO_PRICE.

TASK
1. Run the script (sqlcmd -S . -E -d Inventory_Shipment -i "...\Database\17_Sales_Documents.sql"), show its
   output, append it to Repository\Database\Schema.sql under "-- ===== 17: Sales documents =====" (no USE batch,
   no final report batch; keep the guarded CREATE TYPE / ALTER COLUMN / FK blocks and the demo client seed).
2. Model (Entities + DTOs/Sales/): SalesInvoiceListDto, SalesInvoiceDto (header incl. ids + names + currency
   info + rate + totals + canEdit/canPost/canCancel/canDelete, lines[] SalesInvoiceLineDto, files[], audit[]),
   SaveSalesInvoiceRequest (DocumentDate [Required] DateOnly, DueDate?, BranchId, WarehouseId, ClientId,
   SalesmanId?, PriceListId, RateType 1..3 default 1, ExchangeRate? (null = auto), ReferenceNo [StringLength(100)],
   Notes [StringLength(1000)], Lines[] of SaveSalesInvoiceLineRequest (LineNumber, ItemId, ItemUnitId, WarehouseId,
   ExpiryDate?, Quantity [Range(1,..)], UnitPrice? [Range(0,..)], DiscountPercent? [Range(0,100)],
   ImportRowNumber?, Notes [StringLength(300)]), DraftReference? [StringLength(50)], RowVersion?),
   PostSalesInvoiceRequest (RowVersion?), CancelSalesInvoiceRequest (Reason [Required, StringLength(300)],
   RowVersion?), SalesInvoiceQuery (Search, BranchId?, WarehouseId?, ClientId?, SalesmanId?, Status?, DateFrom?,
   DateTo?, SortBy = DocumentDate, SortDir = desc, Page, PageSize), RateResolutionDto.
   PermissionCatalog: sales.invoices.view/create/post/cancel/delete (620-660), module "Sales".
3. Repository ISalesDocumentRepository (Search, Get via QueryMultiple, Save with the TVP, Post, Cancel, Delete,
   file Add/Get/Delete, ResolveRate); register.
4. Service ISalesInvoiceService: SaveDraftAsync (AllowPriceOverride = user holds sales.invoices.priceoverride;
   MaxDiscountPercent from configuration "Sales:MaxDiscountPercent"), PostAsync, CancelAsync, DeleteAsync,
   GetAsync, SearchAsync, ResolveRateAsync, files, ExportAsync(id) -> xlsx (header block incl. client, currency
   and rate; lines with price/discount/total; totals in the invoice currency + base equivalent).
5. API SalesInvoicesController route api/sales/invoices:
     GET  ?query                                   [HasPermission(sales.invoices.view)] -> PagedResult<SalesInvoiceListDto>
     GET  {id}                                     [view] -> SalesInvoiceDto
     POST                                          [create] SaveSalesInvoiceRequest -> 201 SalesInvoiceDto (draft)
     PUT  {id}                                     [create] -> 200 SalesInvoiceDto
     POST {id}/post                                [post]   -> 200 SalesInvoiceDto (posted, numbered)
     POST {id}/cancel                              [cancel] -> 200 SalesInvoiceDto
     DELETE {id}                                   [delete] -> 204
     GET  {id}/export                              [view] -> xlsx "Invoice_<number or DRAFT-id>.xlsx"
     POST {id}/files (multipart <= 10 MB pdf/xlsx/docx/images) [create] -> 201; GET {id}/files/{fileId} [view];
     DELETE {id}/files/{fileId} [create]
     GET  rate?priceListId=&rateType=1&date=       [view] -> RateResolutionDto
   Import endpoints (existing InvoiceImportController): POST log now accepts optional invoiceId (validated by the
   proc) and a null priceListId; nothing else changes.
6. Build 0 warnings; API starts with "Database schema verified"; Scalar shows the endpoints.

VERIFY (token admin / Admin@12345; a second user WITHOUT sales.invoices.priceoverride) with curl, show output.
Preparation: make sure TVS-AP160 has stock (post an Inventory In of 10 PC at cost 2100 if on-hand is 0) and a
price in Retail USD (2500 seeded; else add it).
  a. GET rate?priceListId=<Retail USD> -> rate 1, isBaseCurrency true. Create a price list in CDF (or EUR) with
     an official rate -> GET rate returns it; with rateType=3 and no market rate -> rate null.
  b. POST a draft: main branch/warehouse, client CLI-0001, price list Retail USD, 2 lines TVS-AP160 PC qty 3
     discount 5 + qty 2 (no price sent) -> 201, documentNumber null (numbered on posting), status Draft,
     lines priced 2500 with priceSource PriceList, totals: subtotal 12500, discount 375, totalAmount 12125,
     totalAmountBase 12125.
  c. As the no-override user, PUT the draft sending unitPrice 9.99 on a line -> 200 but the line still shows 2500
     (PriceList); as admin the same PUT keeps 9.99 with priceSource Manual. A line for an item unit without a
     price in the list -> 400 NO_PRICE with the "Line N: no selling price" message.
  d. POST {id}/post -> 200 status Posted, documentNumber INV-000001; StockMovements has -QuantityBase rows with
     DocumentFamily Sales and UnitCostBase = average cost; totalCostBase set; items on-hand decreased.
  e. PUT the posted invoice -> 409 NOT_DRAFT; a new draft with qty > on-hand -> POST post -> 409 INSUFFICIENT_STOCK.
  f. POST {id}/cancel reason "test" -> 200 Cancelled, reversal rows written, on-hand restored.
  g. Import flow: POST api/sales/invoice-import/log with draftReference "abc-123" (no invoiceId) -> ok; POST a draft
     with draftReference "abc-123" -> sales.InvoiceImportLogs.InvoiceId = the new id and the audit trail shows
     "Imported"; POST log with invoiceId = that id -> second Imported audit row; log with a wrong invoiceId -> 400.
  h. GET {id}/export returns an xlsx; a user with sales.invoices.view only -> 403 on POST.
Report: script output, files changed, every verification result.
```

## Prompt B — Frontend (Sales Invoice page — lines imported from Excel only)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared
ui components, auto-apply filters, document-page skeleton from Inventory In/Out: DocumentHeaderCard,
DocumentLinesGrid, DocumentSummary, DocumentActionBar, AttachmentsDrawer, AuditTrail; ImportInvoiceItemsWizard;
responsive at 390/768/1024/1440). Frontend only. Backend exists under api/sales/invoices (list/get/create/update/
post/cancel/delete/export/files, GET rate?priceListId=&rateType=&date=), api/sales/invoice-import (template/
validate/error-report/log - log now accepts invoiceId), lookups: branches/lookup, warehouses/lookup?branchId=,
price-lists/lookup, parties/lookup?type=Client|Salesman&search=. Error codes: VALIDATION ("Line N: ..."),
CONCURRENCY, NOT_DRAFT, NOT_FOUND, INSUFFICIENT_STOCK, MASTER_INACTIVE, NO_LINES, INVALID_STATUS, NO_PRICE.
Permissions: sales.invoices.view/create/post/cancel/delete, sales.invoices.import, sales.invoices.priceoverride.
Dev: npm run dev, admin / Admin@12345. Test file: docs/samples/Import_Items_Sample.xlsx in the API repo.

Feature: SALES INVOICES - list + document page built on the document skeleton, with ONE difference from
Inventory In: invoice lines are added ONLY through "Import from Excel" (the existing wizard in 'invoice' mode).
No Quick Item Search, no "+ Add Item", no manual item/unit/warehouse editing in this step (manual entry is a
later step - leave a clear extension point in the lines grid component).

TASK
1. src/api/sales/invoices.ts (+ types SalesInvoice, SalesInvoiceLine, RateResolution...). Extend
   src/api/sales/invoiceImport.ts log() with optional invoiceId. Extend ImportInvoiceItemsWizard props with
   optional invoiceId (passed to the log call; draftReference is used only when invoiceId is absent).
2. Navigation: section Sales -> "Sales Invoices" (sales.invoices.view), routes /sales/invoices,
   /sales/invoices/new, /sales/invoices/:id. REMOVE the temporary preview page (/sales/import-preview, its menu
   entry and files) - the wizard now lives in the invoice page.
3. LIST page: FilterBar (search number/reference/client, Branch, Client (searchable Select from parties/lookup
   ?type=Client), Salesman (parties/lookup?type=Salesman), Status All/Draft/Posted/Cancelled, Date from/to, Clear
   Filters); DataTable server-side: #, Invoice No. (grey "DRAFT" badge when null), Date, Client, Salesman, Branch,
   Items, Total (formatted with the invoice currency symbol/code and decimals), Status badge, RowActions: View,
   Edit (drafts, create perm), Post (drafts, post perm, confirm), Cancel (posted, cancel perm, reason dialog),
   Delete (drafts, delete perm, danger confirm). "+ New Invoice" button (create perm).
4. DOCUMENT page (/new, /:id) - modes create / edit (draft) / view (posted or cancelled: read-only + status banner
   with number, posted by/at or cancelled by/at + reason).
   Header card "Invoice Information" (5-column responsive grid like Inventory In):
     Invoice No. (read-only: "Assigned on posting" while draft) | Invoice Date* (default today, max today) |
     Due Date (optional, min = invoice date) | Branch* | Default Warehouse* (filtered by branch, reset on branch
     change) | Client* (searchable Select, parties/lookup?type=Client, option label "CLI-0001 - Name"; on
     selection, when the client has defaultPriceListId, pre-fill Price List with it if the user has not changed
     it manually) | Salesman (searchable Select, parties/lookup?type=Salesman; default = the salesman whose
     userId equals the logged-in user id, when one exists) | Price List* (Select from price-lists/lookup, label
     "Retail USD (USD)") | Rate Type (Segmented/Select: Official / Non-official / Market, default Official) |
     Exchange Rate (NumberInput, 6 decimals; auto-filled from GET rate whenever price list, rate type or invoice
     date changes; editable; when the currency is the base currency show "1 (base currency)" read-only; when the
     API returns rate null show the field empty with an inline warning "No <type> rate for <CUR> on <date> -
     add one in Exchange Rates or enter it manually") | Reference No. (client order) | Notes.
   Lines card "Invoice Lines": toolbar with "Import from Excel" (primary, IconFileSpreadsheet; disabled with a
   tooltip until Branch, Warehouse and Price List are chosen; hidden without sales.invoices.import), "Clear All
   Lines" (confirm), "Export to Excel" (saved documents). Empty state: "No lines yet - import them from an Excel
   file" with the same Import button. Grid (DocumentLinesGrid in 'imported-lines' mode - keep the inline-edit
   plumbing so a later step can enable item editing): #, Item Code, Item Name, Unit ("PC" / "Box (x12)"),
   Warehouse (read-only), Expiry (read-only), On Hand (from the line's onHandBase after save; for new lines call
   stock/on-hand once per item+warehouse; red when qty x formula > on hand), Qty (NumberInput, editable), Unit
   Price (editable only with sales.invoices.priceoverride, otherwise read-only with tooltip "Price list price -
   override permission required"; show a small "manual" badge when priceSource = Manual), Disc % (NumberInput
   0-100, editable), Line Total (read-only = qty x price x (1 - disc/100), invoice currency), Notes (editable),
   Delete icon. Row number badge shows the Excel row (importRowNumber) in a tooltip.
   Import wizard: <ImportInvoiceItemsWizard mode="invoice" header={{ branchId, warehouseId, priceListId,
   currencyCode, decimalPlaces }} draftReference={draftRef} invoiceId={id} onImported={append} />. draftRef = a
   GUID generated once per NEW-document page and sent as draftReference on the first save; for a saved draft
   pass invoiceId instead. append(): merge into an existing line when item + unit + warehouse + price + discount
   + expiry + notes are identical (sum quantities, keep the first importRowNumber), otherwise add a line; after
   importing show notify.success("N line(s) imported") and mark the form dirty.
   Summary card (bottom-right): Total Items, Total Quantity (base units), Subtotal, Discount, Grand Total in the
   invoice currency (symbol + code, decimalPlaces); when the currency is not the base currency add a muted line
   "≈ <base amount> USD at <rate>". A left card with the audit trail (last 5, "show all").
   Action bar (top-right, sticky; collapses into a menu below 768 px): Attachments (n) (after first save),
   Import from Excel, Save Draft, Cancel (back with unsaved-changes confirm), Save & Post (primary = save then
   post; confirm "Post this invoice? Stock will be removed from the warehouses and the invoice number will be
   assigned."). View mode: Export to Excel, Cancel Invoice (posted, cancel perm, reason dialog), Back.
   Behaviour: changing Price List or Branch after lines exist shows an info Alert "Prices are taken from the
   selected price list when the invoice is saved" (the API re-prices lines for users without the override
   permission); client-side validation before save (date, branch, warehouse, client, price list, rate > 0, at
   least one line, qty >= 1, discount 0-100); API VALIDATION / NO_PRICE messages starting with "Line N:"
   highlight that row + tooltip + notify; INSUFFICIENT_STOCK / NO_LINES / NOT_DRAFT / MASTER_INACTIVE shown as
   notify with the API message; CONCURRENCY notifies and reloads. Totals recalculate on every change;
   unsaved-changes guard; posted/cancelled documents fully read-only (inputs replaced by text).
5. docs/frontend-conventions.md: add "Sales invoice page" (how lines are imported, draftReference/invoiceId rule,
   where manual entry will plug in).
6. Quality: typecheck / lint / build clean; all breakpoints; permission gating (view-only users see read-only
   invoices and no buttons; no import permission = no Import button; no priceoverride = read-only prices).

VERIFY (API running) with screenshots at 1440 and 390:
  a. New Invoice: defaults (today, main branch + warehouse, Official rate 1 for Retail USD); choosing client
     CLI-0001 pre-fills its default price list; Import button disabled until the price list is chosen.
  b. Import from Excel with docs/samples/Import_Items_Sample.xlsx -> wizard validates (prices from Retail USD),
     Import Valid Rows -> lines appear with prices, totals computed; Save Draft -> "DRAFT" badge, audit shows
     Created + Imported (draftReference linked); edit a qty and a discount -> Save Draft -> Updated.
  c. Import again on the saved draft (invoiceId path) -> duplicate rows merge into existing lines, audit gets a
     second Imported entry.
  d. Save & Post -> confirm -> banner Posted with INV-0000xx, read-only; Items page On Hand decreased; Export to
     Excel downloads; Attachments drawer uploads a PDF.
  e. A draft with qty above stock -> Save & Post shows the INSUFFICIENT_STOCK message; a line whose unit has no
     price in the chosen list -> NO_PRICE message highlights the line.
  f. Cancel the posted invoice (reason required) -> Cancelled badge, On Hand restored.
  g. A CDF (or EUR) price list: rate auto-filled from Exchange Rates, summary shows "≈ ... USD"; with no rate
     defined the warning appears and a manual rate lets the invoice save.
  h. List filters auto-apply (client, salesman, status, dates); the old preview page is gone from the menu;
     a view-only user sees everything read-only; a user without priceoverride cannot edit prices.
Report: files added/changed/removed, navigation changes, every verification result.
```
