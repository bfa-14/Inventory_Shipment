# Batch 3 — Sales Invoice (full page: manual lines + Excel import), no Sales Order / Return yet

Point **9**. Replaces the earlier `20-sales-invoice.md` (do not run that one). SQL already in place: script 17
(sales documents), 19 (per-branch numbering `INV-KLW-000001`, header warehouse, moving-average COGS), 20 (import
template). The API already has the minimal invoice engine from batch "Import Sales" (import-post, get, rate); this
prompt completes it. Requires batches 1 and 2 applied.

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern as in the stock documents. Existing: SalesInvoicesController (import-post, GET {id}, rate) +
ISalesInvoiceService / ISalesDocumentRepository (Save, Post, Delete, Get, ResolveRate). Script 17 procedures:
sales.usp_SalesDocument_Search / _Get / _Save / _Post / _Cancel / _Delete, usp_SalesDocumentFile_Add/_Get/_Delete
(read the header of 17_Sales_Documents.sql; 19 re-created Save/Post: numbering per branch, header warehouse).
Errors 64xxx: 64000 VALIDATION, 64004 CONCURRENCY, 64005 NOT_DRAFT, 64006 NOT_FOUND, 64007 INSUFFICIENT_STOCK,
64008 MASTER_INACTIVE, 64009 NO_LINES, 64010 INVALID_STATUS, 64011 NO_PRICE.

TASK - complete api/sales/invoices (type SINV only; SO / SRET later):
  GET  ?query (SalesInvoiceQuery: search, branchId, warehouseId, clientId, salesmanId, status, dateFrom, dateTo,
       sortBy DocumentNumber|DocumentDate|ClientName|Status|TotalAmount|CreatedAtUtc, sortDir, page, pageSize)
       [view] -> PagedResult<SalesInvoiceListDto> (usp_SalesDocument_Search with 'SINV')
  GET  {id} [view]; POST [create] -> 201 draft; PUT {id} [create]; POST {id}/post [post]; POST {id}/cancel
       [cancel] (reason); DELETE {id} [delete]; GET {id}/export [view] (xlsx: header incl. client, currency, rate;
       lines; totals + base equivalent); POST/GET/DELETE {id}/files... [create/view/create]; GET rate (exists).
  POST bulk-post { ids } [post] and POST bulk-delete { ids } [delete] via the shared BulkDocumentActions helper.
  POST import-create { header fields of SaveSalesInvoiceRequest without lines + lines[] + postImmediately }
       [create/post] -> ImportCreateResult: one invoice per warehouse (shared GroupLinesByWarehouse helper);
       draftReference handling as in import-post (logs attached to the FIRST created invoice; the others get an
       audit "Imported" row through usp_InvoiceImport_Log with their invoiceId).
  Keep import-post working (the hidden page still calls it).
  Price lookup for manual lines: GET api/masterdata/unit-prices/resolve?itemUnitId=&priceListId=&branchId=
  [Authorize] -> { price, source: Branch|AllBranches, currencyCode } or 404-style empty result { price: null }
  (masterdata.usp_UnitPrice_Resolve exists since script 12 - add the endpoint if it is not there yet).
  Save rules: AllowPriceOverride = user holds sales.invoices.priceoverride; MaxDiscountPercent from
  "Sales:MaxDiscountPercent"; the document warehouse is the header's (lines send it anyway).
  SalesInvoiceListDto: id, documentNumber (null = draft), documentDate, dueDate, branchName, warehouseName,
  clientCode, clientName, salesmanName, currencyCode, currencySymbol, decimalPlaces, totalItems, totalQuantity,
  totalAmount, totalAmountBase, status (Draft|Posted|Cancelled), postedAtUtc, postedByName, createdAtUtc,
  createdByName, rowVersion.
  Build 0 warnings; "Database schema verified".

VERIFY (token admin / Admin@12345; on-hand of TVS-AP160 >= 10) with curl, show output:
  a. GET list with status=1 -> paged drafts; sort by ClientName works.
  b. POST draft (client CLI-0001, Retail USD, 2 lines) -> 201 documentNumber null; PUT changes qty -> 200;
     POST {id}/post -> INV-<BRANCH>-000001 (per-branch sequence), movements written, COGS = moving average.
  c. POST {id}/cancel -> Cancelled, reversal rows; DELETE a draft -> 204; DELETE a posted -> 409 NOT_DRAFT.
  d. bulk-post of 2 drafts (one with insufficient stock) -> 1 ok, 1 INSUFFICIENT_STOCK.
  e. import-create with lines in 2 warehouses, postImmediately true -> 2 invoices, 2 numbers.
  f. export -> xlsx; a view-only user -> 403 on POST.
Report: files changed, every verification result.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared
ui components, document-page skeleton, DocumentListPage bulk actions, ImportInvoiceItemsWizard with the
one-document-per-warehouse flow, useDocumentTypes()). Frontend only. Backend: api/sales/invoices (list, get,
create, update, post, cancel, delete, export, files, rate, bulk-post, bulk-delete, import-create),
api/sales/invoice-import (template/validate/error-report/log), lookups (branches, warehouses?branchId=,
price-lists, parties?type=Client|Salesman, items/lookup?search=, items/{id}, stock/on-hand). Error codes:
VALIDATION / NO_PRICE ("Line N: ..."), CONCURRENCY, NOT_DRAFT, NOT_FOUND, INSUFFICIENT_STOCK, MASTER_INACTIVE,
NO_LINES, INVALID_STATUS. Permissions: sales.invoices.view/create/post/cancel/delete/import/priceoverride.
Dev: npm run dev, admin / Admin@12345.

Feature: SALES INVOICES - list + full document page on the skeleton (like Inventory In), pricing driven by the
type configuration (SINV = PriceList: price editable only with sales.invoices.priceoverride).

TASK
1. src/api/sales/invoices.ts completed (list/get/create/update/post/cancel/delete/export/files/bulk/importCreate).
2. Navigation: Sales > "Sales Invoices" (sales.invoices.view); routes /sales/invoices, /new, /:id. The hidden
   "Import Sales from Excel" page stays hidden.
3. LIST: FilterBar (search number/reference/client, Branch, Client (searchable), Salesman, Status
   All/Draft/Posted/Cancelled, Date from/to); DataTable: selection column (bulk Post / Delete like Inventory In),
   #, Invoice No. (DRAFT badge when null), Date, Client, Salesman, Branch, Warehouse, Items, Total (currency symbol
   + code, decimals), Status badge, RowActions View / Edit / Post / Cancel / Delete (permission + status gated);
   "+ New Invoice".
4. DOCUMENT page: header card "Invoice Information": Invoice No. (read-only, "Assigned on posting"), Invoice
   Date*, Due Date, Branch*, Warehouse* (filtered by branch), Client* (searchable; pre-fills Price List from the
   client's default when the user has not changed it), Salesman (default = the salesman linked to the logged-in
   user), Price List* (shows currency), Rate Type + Exchange Rate (auto from GET rate; read-only "1 (base
   currency)" for USD; warning + manual entry when none), Reference No., Notes.
   Quick Item Search (barcode / code + Enter, as Inventory In) and "+ Add Item": new lines get unit = sales unit
   (else base), qty 1, price = GET api/masterdata/unit-prices/resolve?itemUnitId=&priceListId=&branchId= (when
   no price: line marked red "No price in <list>" and save is blocked with the NO_PRICE message), discount 0.
   Lines grid: #, Item Code (link), Item Name, Unit (Select among the item's units - price re-resolved on change),
   On Hand (red when qty x formula > on hand), Qty, Unit Price (editable only with priceoverride; badge "manual"
   when it differs from the list price), Disc %, Line Total, Notes, Delete. Toolbar: "+ Add Item", "Import from
   Excel" (wizard in invoice mode with checkStock: true; multi-warehouse files -> one invoice per warehouse via
   importCreate), "Clear All Lines", "Export to Excel" (saved).
   Summary card: Total Items, Total Quantity, Subtotal, Discount, Grand Total (invoice currency) + "≈ ... USD at
   <rate>" when not base; audit trail card. Action bar: Attachments (n), Import from Excel, Save Draft, Cancel,
   Save & Post (confirm "Post this invoice? Stock will be removed from <warehouse> and the number assigned.").
   View mode: Export, Cancel Invoice (reason), Back. Validation / error handling / unsaved guard / read-only after
   posting exactly as the Inventory In page.
5. docs/frontend-conventions.md: "Sales invoice page" section.
6. Quality: typecheck / lint / build clean; all breakpoints; permission gating (no priceoverride = read-only
   prices; view-only users read-only).

VERIFY (API running) with screenshots at 1440 and 390:
  a. New invoice: defaults; client pre-fills price list; scan TVS-AP160 -> line with sales unit and list price;
     change unit -> price re-resolved; qty above stock turns red.
  b. Save Draft -> DRAFT badge; Save & Post -> INV-<BRANCH>-0000xx banner, read-only; Items page On Hand down;
     Export works; Attachments upload.
  c. Import from Excel with a two-warehouse file -> "Create one invoice per warehouse" -> 2 invoices listed.
  d. List: filters auto-apply; select 2 drafts -> Post selected -> results modal.
  e. Cancel a posted invoice (reason) -> Cancelled, On Hand restored.
  f. A user without priceoverride cannot edit prices; a view-only user sees read-only invoices.
Report: files added/changed, navigation changes, every verification result.
```
