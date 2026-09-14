# Import Sales from Excel → validate (incl. stock) → post to Stock Movements — SQL + VS Code prompts

What changes: the "Import Items (preview)" page stops being a sandbox. It becomes **Sales → Import Sales from
Excel**: choose branch / warehouse / price list / client, import the file, see every error in the preview
(**quantities are now checked against the stock on hand, cumulatively per item + warehouse**), fix the lines,
then **Post to Stock**. Posting stores a real posted Sales Invoice (script 17: number `INV-000001`, COGS, audit)
and writes the negative rows to `inventory.StockMovements`. No invoice list/page is built in this step (that is
prompt 20, later — it will simply show the invoices posted from here).

Run order: `17_Sales_Documents.sql` (if not run yet) → `18_Sales_ImportStockCheck.sql` → Prompt A (API) →
Prompt B (Web). Test file: `docs\samples\Import_Items_Sample.xlsx` (needs stock: post an Inventory In of
TVS-AP160 first).

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern: Dapper repositories over stored procedures (SqlErrors -> BusinessRuleException), services
returning Result with codes, controllers with [HasPermission], PermissionCatalog, Schema.sql embedded. The
Inventory In/Out implementation (StockDocuments*) is the template for document code.

Feature: "Import Sales from Excel -> validate (with stock) -> post to stock". Scripts already written (read both
headers): D:\VSProjects\Inventory_Shipment\Database\17_Sales_Documents.sql (sales documents: tables, TVP
sales.tvp_SalesDocumentLine, usp_SalesDocument_Save / _Post / _Get / _Delete / _Search / _Cancel / files /
_ResolveRate, permissions sales.invoices.view/create/post/cancel/delete 620-660, errors 64xxx) and
18_Sales_ImportStockCheck.sql (sales.usp_InvoiceImport_Validate re-created with @CheckStock BIT = 0 and two new
output columns OnHandBase, RequiredBase; message "Insufficient stock for X in WH: available a, required r (with
rows ...)").
THROW mapping (64xxx): 64000 Validation VALIDATION; 64004 Conflict CONCURRENCY; 64005 Conflict NOT_DRAFT; 64006
NotFound; 64007 Conflict INSUFFICIENT_STOCK; 64008 Validation MASTER_INACTIVE; 64009 Validation NO_LINES; 64010
Conflict INVALID_STATUS; 64011 Validation NO_PRICE.

TASK
1. Run both scripts in order (sqlcmd -S . -E -d Inventory_Shipment -i "..."), show their output (18 ends with a
   2-row self-test: row 2 Valid or Error depending on stock, row 3 Error "Insufficient stock ... (with rows 2)"),
   append them to Repository\Database\Schema.sql under "-- ===== 17: Sales documents =====" and
   "-- ===== 18: Import stock check =====" (no USE batches, no self-test / report batches; keep the guarded
   CREATE TYPE / ALTER COLUMN / FK blocks and the demo client seed of 17).
2. Import validate endpoint (existing InvoiceImportController / service / parser): add an optional form field
   checkStock (bool, default false) passed to the proc; map the new columns OnHandBase / RequiredBase into the row
   DTO (onHandBase, requiredBase, nullable ints). POST log: priceListId optional and invoiceId optional (the proc
   validates it). Consolidation (rule 16) unchanged.
3. Sales documents - MINIMAL engine now (the full invoice API is a later prompt, so design it to grow):
   - Model (Entities + DTOs/Sales/): SalesInvoiceDto (header incl. names, currency code/symbol/decimals, rate,
     totals incl. totalAmountBase/totalCostBase, status, documentNumber, posted info, lines[] SalesInvoiceLineDto,
     audit[]), SaveSalesInvoiceRequest (DocumentDate [Required], DueDate?, BranchId, WarehouseId, ClientId,
     SalesmanId?, PriceListId, RateType 1..3 = 1, ExchangeRate?, ReferenceNo [StringLength(100)], Notes
     [StringLength(1000)], Lines[] { LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate?, Quantity
     [Range(1,..)], UnitPrice?, DiscountPercent? [Range(0,100)], ImportRowNumber?, Notes [StringLength(300)] },
     DraftReference? [StringLength(50)]), ImportPostResult (id, documentNumber, totalItems, totalQuantity,
     subtotal, totalDiscount, totalAmount, currencyCode, currencySymbol, decimalPlaces, totalAmountBase,
     baseCurrencyCode, exchangeRate, postedAtUtc, movementsWritten = line count).
   - Repository ISalesDocumentRepository: Save (TVP), Post, Delete, Get (QueryMultiple: header, lines, files,
     audit), ResolveRate. (Search / Cancel / files come with the invoice page prompt - leave TODOs.)
   - Service ISalesInvoiceService.ImportPostAsync(request, user): AllowPriceOverride = user holds
     sales.invoices.priceoverride; MaxDiscountPercent from configuration "Sales:MaxDiscountPercent";
     1) Save draft (usp_SalesDocument_Save) 2) Post (usp_SalesDocument_Post) 3) Get -> ImportPostResult.
     If step 2 throws, DELETE the draft (usp_SalesDocument_Delete) and return the post error unchanged (the page
     must not be left with an invisible draft). Also GetAsync(id) and ResolveRateAsync.
   - PermissionCatalog: sales.invoices.view/create/post/cancel/delete (620-660), module Sales.
4. API SalesInvoicesController route api/sales/invoices (only these for now):
     POST import-post   [HasPermission(sales.invoices.post)] SaveSalesInvoiceRequest -> 200 ImportPostResult
                        (the caller must also hold sales.invoices.create - check in the service, 403 otherwise)
     GET  {id}          [view] -> SalesInvoiceDto
     GET  rate?priceListId=&rateType=1&date=   [view] -> { currencyCode, symbol, decimalPlaces, isBaseCurrency,
                                                          rateType, rate (null when none), rateDate, baseCurrencyCode }
   Problem details carry the 64xxx codes above; VALIDATION / NO_PRICE messages start with "Line N:".
5. Build 0 warnings; API starts with "Database schema verified".

VERIFY (token admin / Admin@12345) with curl, show output. Preparation: post an Inventory In of TVS-AP160 PC
qty 10 cost 2100 so the on-hand is 10; Retail USD price 2500 exists (seed).
  a. POST invoice-import/validate with checkStock=true and rows: TVS-AP160 qty 4; TVS-AP160 qty 7; XYZ-999 qty 1
     -> row 1 Valid (onHandBase 10, requiredBase 4), row 2 Error "Insufficient stock ... available 10, required 11
     (with rows 2)" (requiredBase 11), row 3 Error does not exist. Without checkStock row 2 is Valid.
  b. POST import-post: main branch/warehouse, client CLI-0001, Retail USD, date today, lines TVS-AP160 PC qty 4
     discount 5 -> 200 { documentNumber "INV-000001", totalAmount 9500, currencyCode USD, movementsWritten 1 };
     SELECT inventory.StockMovements -> a -4 row with DocumentFamily Sales, DocumentNumber INV-000001,
     UnitCostBase 2100; GET api/inventory/items/{id} -> onHand 6; GET api/sales/invoices/{id} -> status Posted,
     audit Created + Posted.
  c. POST import-post with qty 7 (only 6 left) -> 409 INSUFFICIENT_STOCK "available 6, required 7"; SELECT
     sales.SalesDocuments -> NO draft was left behind.
  d. POST import-post with a unit that has no price in Retail USD and no manual price -> 400 NO_PRICE "Line 1: no
     selling price ..."; with a discount of 150 -> 400 VALIDATION.
  e. A user with sales.invoices.view only -> 403 on import-post; GET rate for Retail USD -> rate 1, base true.
Report: script output, files changed, every verification result.
```

## Prompt B — Frontend (Import Sales from Excel → Post to Stock)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared
ui components, ImportInvoiceItemsWizard, responsive at 390/768/1024/1440). Frontend only. Backend exists:
api/sales/invoice-import/validate (multipart: file, branchId, warehouseId, priceListId, NEW checkStock=true ->
rows now carry onHandBase, requiredBase and stock errors), POST api/sales/invoices/import-post
(SaveSalesInvoiceRequest -> ImportPostResult { id, documentNumber, totalItems, totalQuantity, subtotal,
totalDiscount, totalAmount, currencyCode, currencySymbol, decimalPlaces, totalAmountBase, baseCurrencyCode,
exchangeRate, postedAtUtc, movementsWritten }), GET api/sales/invoices/rate?priceListId=&rateType=&date=,
GET api/sales/invoices/{id}; lookups branches/lookup, warehouses/lookup?branchId=, price-lists/lookup,
parties/lookup?type=Client|Salesman&search=, api/inventory/stock/on-hand?itemId=&warehouseId=. Error codes:
VALIDATION and NO_PRICE ("Line N: ..."), INSUFFICIENT_STOCK ("Insufficient stock for <code> in <warehouse>: ..."),
MASTER_INACTIVE, NO_LINES, CONCURRENCY. Permissions: sales.invoices.import (wizard), sales.invoices.create +
sales.invoices.post (posting), sales.invoices.priceoverride (manual prices). Dev: npm run dev, admin / Admin@12345.

Feature: turn the sandbox page /sales/import-preview into the real "Import Sales from Excel" page that validates
the file (including stock) and POSTS the lines to the stock movements as a sales invoice. Keep the route; rename
the menu entry to "Import Sales from Excel" (permission sales.invoices.import, remove the "Preview" badge and the
preview Alert).

TASK
1. src/api/sales/invoices.ts (importPost, get, rate) + types; add checkStock to the validate call and
   onHandBase / requiredBase to the import row type; the wizard gets a new prop checkStock?: boolean (passed
   through) - in 'invoice' mode the preview table shows an "On Hand" column (onHandBase, base units) and stock
   errors appear like any other error (badge Error + message). No other wizard changes.
2. Page header card "Sales Import" (responsive grid): Branch* | Default Warehouse* (filtered by branch) |
   Price List* (label "Retail USD (USD)") | Client* (searchable Select from parties/lookup?type=Client, option
   "CLI-0001 - Name"; default = the first client when the list has exactly one, else empty; selecting a client
   with defaultPriceListId pre-fills Price List if the user has not changed it) | Salesman (optional, searchable;
   default = the salesman whose userId equals the logged-in user) | Date* (DateInput, default today, max today) |
   Rate Type + Exchange Rate (auto from GET rate on price list / type / date change; read-only "1 (base currency)"
   for the base currency; editable otherwise; warning when null) | Reference No. | Notes.
   "Import from Excel" button (primary; disabled with tooltip until Branch, Warehouse, Price List are chosen)
   opens the wizard in 'invoice' mode with checkStock: true and header { branchId, warehouseId, priceListId,
   currencyCode, decimalPlaces }; onImported appends lines (merge identical item+unit+warehouse+price+discount+
   expiry+notes lines by summing quantities). Changing branch / warehouse / price list after lines exist asks
   for confirmation and clears the lines (they were validated against the old header).
3. Lines grid (existing grid, improved): #, Item (code + name), Unit, Warehouse, On Hand (base units, fetched via
   stock/on-hand per distinct item+warehouse and cached; refreshed after posting), Qty (editable NumberInput
   min 1), Price (editable only with sales.invoices.priceoverride; otherwise read-only + tooltip), Discount %
   (editable 0-100), Line total, Notes (editable), Delete. Client-side stock check: for each item+warehouse
   compute the cumulative required base quantity (qty x packingFormula) in row order; rows that exceed the
   on-hand are highlighted red with a tooltip "Insufficient stock: available a, required r" and a red summary
   line "N line(s) exceed the stock on hand" - the Post button is disabled while any exists. Totals card:
   Subtotal, Total discount, Grand total (currency), "≈ ... USD at <rate>" when not base currency.
4. Action bar (top-right, sticky; menu below 768 px): "Import from Excel", "Clear all" (confirm), "Post to Stock"
   (primary, IconTruckDelivery/IconArrowBarToDown; visible with sales.invoices.post; disabled when no lines, header
   incomplete, rate missing, or stock errors). Click -> confirm dialog "Post N line(s) to stock? A sales invoice
   will be created and posted, and the stock of <warehouse(s)> will be reduced. This cannot be undone here." ->
   POST import-post with the header + lines (lineNumber = row order, importRowNumber from the wizard row) ->
   on success replace the lines area with a success panel: green Alert "Posted INV-000001 - N line(s) written
   to the stock movements", the totals, buttons "Start a new import" (clears everything, keeps the header) and
   "Export to Excel" (calls GET {id}/export when the endpoint exists - otherwise hide it); notify.success.
   Errors: VALIDATION / NO_PRICE "Line N:" -> highlight that row + tooltip + notify; INSUFFICIENT_STOCK ->
   notify with the API message and highlight the rows of that item code + warehouse, refresh their On Hand;
   MASTER_INACTIVE / NO_LINES / CONCURRENCY -> notify. The header stays enabled so the user can fix and re-post.
5. Unsaved-lines guard on navigation ("Imported lines are not posted yet"). Item Definition On Hand shows the
   decrease after posting.
6. docs/frontend-conventions.md: replace the "Sales import wizard" preview notes with "Import Sales from Excel
   page" (flow: validate with checkStock -> lines -> import-post; stock check rules; what the future invoice
   page reuses).
7. Quality: typecheck / lint / build clean; all breakpoints (grid scrolls horizontally on mobile); permission
   gating (no post permission = no Post button; no import permission = page hidden from the menu).

VERIFY (API running; on-hand of TVS-AP160 = 10 after an Inventory In) with screenshots at 1440 and 390:
  a. Header defaults (today, main branch/warehouse, client pre-selected when only one exists, rate 1 for USD);
     Import disabled until the price list is chosen.
  b. Import docs/samples/Import_Items_Sample.xlsx -> the wizard preview shows On Hand 10 and the rows whose
     cumulative quantity exceeds 10 as Errors with the "Insufficient stock ... (with rows ...)" message; import
     the valid rows -> grid shows On Hand and totals.
  c. Increase a Qty in the grid above the remaining stock -> row turns red, Post disabled, summary line shown;
     put it back -> Post enabled.
  d. Post to Stock -> confirm -> success panel "Posted INV-000001 - N line(s) written to the stock movements";
     Item Definition On Hand decreased accordingly; Start a new import clears the lines.
  e. Import again with more than the remaining stock but bypass the client check by editing after validation
     (or run two browsers): the API's INSUFFICIENT_STOCK message is shown and the rows highlighted; no draft is
     left (Inventory In/Out lists unchanged, GET api/sales/invoices/{id} of the failed attempt does not exist).
  f. A user without priceoverride sees read-only prices; without sales.invoices.post sees no Post button; the
     menu entry reads "Import Sales from Excel" without the Preview badge.
Report: files added/changed, navigation changes, every verification result.
```
