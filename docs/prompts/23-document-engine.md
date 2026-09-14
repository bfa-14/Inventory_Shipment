# Batch 2 — Document engine: per-branch numbering, one document per warehouse, bulk posting, DefaultPricing, common import template, item purchasing

Points covered: **4** (numbering `INV-KLW-000001` per type + branch), **5** (Excel import creates one document per
warehouse), **7** (multi-select posting on every document list), **8** (`DefaultPricing` / `PriceEditable` in
`inventory.DocumentTypes` + configuration page), **11** (one import template for all types with a "Document Type"
column), plus the recommendations: moving average cost kept on the item, last cost / last supplier, default
supplier + lead time on the item.

SQL first (SSMS, in this order): `19_Core_DocumentEngine.sql` → `20_Import_CommonTemplate.sql` →
`21_Purchase_Documents.sql` (21 is used by batch 4 but the API's Schema.sql must contain all three).
Then Prompt A (API folder), then Prompt B (Web folder).

Numbering note: branch codes are cut to 8 characters inside document numbers — keep them short (KLW, LBB…).
Existing documents keep their old numbers.

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern: Dapper repositories over stored procedures (SqlErrors -> BusinessRuleException), services
returning Result with codes, controllers with [HasPermission], PermissionCatalog, Schema.sql embedded, ClosedXML.

Scripts already written - read the three headers: D:\VSProjects\Inventory_Shipment\Database\19_Core_DocumentEngine.sql,
20_Import_CommonTemplate.sql, 21_Purchase_Documents.sql. What changed for THIS prompt (21 is wired in a later prompt):
- inventory.DocumentTypes: + DefaultPricing ('Cost'|'PriceList'|'None'), PriceEditable BIT, NumberPerBranch BIT;
  usp_DocumentType_List returns them; NEW usp_DocumentType_Update(@Id, @Name, @NumberPrefix, @NumberLength,
  @NumberOnPost, @RequiresReason, @DefaultPricing, @PriceEditable, @NumberPerBranch, @IsActive, @RowVersion, @UserId).
- Numbering per branch inside the procedures (nothing to do in the API except showing the numbers; they are longer:
  "IN-KLW-000012", "INV-KLW-000001").
- ONE DOCUMENT = ONE WAREHOUSE: the Save procedures ignore the per-line warehouse and use the header's.
- inventory.Items: + AverageCost, LastCost, LastSupplierId, LastPurchaseAtUtc, DefaultSupplierId, LeadTimeDays;
  usp_Item_Search / usp_Item_Get return AverageCost, LastCost, DefaultSupplierId/Code/Name, LeadTimeDays,
  LastSupplierId/Name, LastPurchaseAtUtc; NEW usp_Item_SetPurchasing(@Id, @DefaultSupplierId, @LeadTimeDays, @UserId).
- sales.tvp_InvoiceImportRow re-created with DocumentTypeCode NVARCHAR(50) as the LAST column (DataTable order!);
  sales.usp_InvoiceImport_Validate: + @DocumentTypeCode (the page's type) and output columns RowDocumentTypeCode,
  OnHandBase, RequiredBase; rows whose "Document Type" cell names another type are Errors.

TASK
1. Run the three scripts in order (sqlcmd -S . -E -d Inventory_Shipment -i "..."), show their output, append each to
   Repository\Database\Schema.sql under "-- ===== 19 =====", "-- ===== 20 =====", "-- ===== 21 =====" (no USE, no
   self-test / report batches; keep every guarded ALTER / CREATE TYPE / DROP TYPE block exactly as written - script
   20 drops and re-creates a table type, that block must stay guarded so startup is idempotent).
2. Document types configuration:
   - DocumentTypeDto + defaultPricing, priceEditable, numberPerBranch; UpdateDocumentTypeRequest (all editable
     fields + RowVersion); PUT api/inventory/document-types/{id} [HasPermission(inventory.documenttypes.manage)]
     -> DocumentTypeDto; GET api/inventory/document-types stays [Authorize] (every document page reads it).
3. Items purchasing + costs:
   - ItemDto / ItemListDto: averageCost, lastCost, defaultSupplierId, defaultSupplierCode/Name, leadTimeDays,
     lastSupplierId/Name, lastPurchaseAtUtc. Create/Update item requests: + DefaultSupplierId?, LeadTimeDays?; the
     service calls usp_Item_Create/Update as today and then usp_Item_SetPurchasing in the same call (no RowVersion
     check on the second step); the returned ItemDto is re-read after both.
4. Common import template (existing InvoiceImportController / parser / service):
   - Parser: new optional column "Document Type" (aliases: Type, Doc Type, Invoice Type) -> DocumentTypeCode text,
     appended as the last DataTable column. Mandatory columns unchanged.
   - POST validate: + documentTypeCode (form field, required from now on: the page's type) -> passed to the proc;
     checkStock as before; rows get rowDocumentTypeCode, onHandBase, requiredBase.
   - GET template?documentTypeCode=INV_IN: the SAME workbook for every type, with the "Document Type" column
     pre-filled with the requested code in the example rows, the Instructions sheet listing all type codes and
     names (from usp_DocumentType_List) and the rule "one document is created per warehouse found in the file",
     and the price column header reading "Unit Price / Cost". File name "Import_<TYPE>_Template.xlsx".
   - Error report: + Document Type column.
5. Bulk posting for every family (Inventory now; Sales / Purchase controllers reuse the same service helper):
   - POST api/inventory/stock-documents/bulk-post { ids: int[] } [Authorize; per-document permission check as today]
     -> BulkActionResult { requested, succeeded, failed, results[] { id, documentNumber, ok, code, message } }.
     Each document is posted in its OWN call/transaction; one failure does not stop the others; results keep the
     input order. Also POST .../bulk-delete { ids } (drafts only, same result shape).
   - Put the loop + result assembly in a shared BulkDocumentActions helper (generic over a Func<int, Task<Result>>)
     so the sales and purchase controllers only pass their post/delete delegates.
6. Import creates ONE DOCUMENT PER WAREHOUSE (server side, so every family behaves the same):
   - POST api/inventory/stock-documents/import-create { documentTypeCode, documentDate, branchId, reasonId?,
     referenceNo?, notes?, lines[] (the validated wizard rows incl. warehouseId, itemId, itemUnitId, quantity,
     unitPrice, discountPercent, expiryDate, notes, importRowNumber), postImmediately: bool }
     [create (+ post when postImmediately)] -> ImportCreateResult { documents[] { id, documentNumber, warehouseId,
     warehouseName, lineCount, status }, created, posted, failed[] { warehouseId, warehouseName, code, message } }.
     Group the lines by warehouseId, create one draft per group (header copied, WarehouseId = the group's), post
     each when requested (independent transactions; a failed post leaves that document as a draft and reports it).
   - The same endpoint shape will be added to sales / purchase controllers in their prompts - implement the grouping
     in a shared helper (GroupLinesByWarehouse<TLine>) now.
7. PermissionCatalog: nothing new except keeping inventory.documenttypes.manage (module Configuration).
8. Build 0 warnings; API starts with "Database schema verified"; run the existing verification of Inventory In
   once more (regression: numbers now look like IN-KLW-000013).

VERIFY (token admin / Admin@12345) with curl, show output:
  a. GET document-types -> 8 rows with defaultPricing/priceEditable/numberPerBranch (INV_OUT priceEditable false,
     SINV PriceList); PUT SINV numberLength 5 -> ok; put it back to 6.
  b. POST an INV_IN draft -> documentNumber "IN-<BRANCHCODE>-000001" (first per-branch number for that branch);
     a second branch gets its own 000001.
  c. PUT an item with defaultSupplierId = SUP-0001, leadTimeDays 14 -> GET shows them; GET after posting an
     Inventory In shows averageCost/lastCost updated by the moving average (post 10 @ 2000 then 10 @ 3000 on an
     item with 0 stock -> averageCost 2500, lastCost 3000).
  d. GET invoice-import/template?documentTypeCode=INV_IN -> xlsx with the Document Type column; POST validate with
     documentTypeCode=INV_IN and a file containing a row typed "PINV" -> that row is Error "This row is for
     Purchase Invoice (PINV), not for Inventory In."; a row with the type blank -> Valid.
  e. POST import-create for INV_IN with lines in WH-001 and WH-002, postImmediately true -> 2 documents, both
     posted, numbers returned; StockMovements show both.
  f. POST bulk-post with 3 draft ids where one has no lines -> succeeded 2, failed 1 with code NO_LINES;
     bulk-delete of the failed one -> ok.
Report: script output, files changed, every verification result.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared ui
components, document-page skeleton, ImportInvoiceItemsWizard). Frontend only. Backend (new): GET/PUT
api/inventory/document-types (defaultPricing, priceEditable, numberPerBranch, numberOnPost...), items with
averageCost/lastCost/defaultSupplier*/leadTimeDays, invoice-import/validate (+ documentTypeCode, rows carry
rowDocumentTypeCode/onHandBase/requiredBase), invoice-import/template?documentTypeCode=, stock-documents/bulk-post,
bulk-delete, import-create (creates one document per warehouse). Dev: npm run dev, admin / Admin@12345.

TASK
1. Configuration page: Configuration > Document Types (permission inventory.documenttypes.manage): DataTable of
   the 8 types (Code, Name, Family, Stock direction badge, Prefix, Next number, Length, Number on post, Number per
   branch, Requires reason, Default pricing, Price editable, Active) with an Edit modal (all editable fields;
   Code / Family / Stock direction read-only) and a warning Alert "Changing the prefix or the numbering applies to
   NEW documents only". Add "Configuration" section to navigation.ts (after BACKOFFICE).
2. Document pages read the type configuration (a small useDocumentTypes() hook, cached): the price/cost column
   label and behaviour come from defaultPricing / priceEditable - Cost + editable = editable cost (Inventory In,
   purchase docs), Cost + not editable = read-only average (Inventory Out), PriceList = price list price editable
   only with the override permission (sales). Remove the hard-coded INV_IN / INV_OUT switches from batch 1 in favour
   of this. Document numbers are longer now (IN-KLW-000012) - widen the number column / badges, no truncation.
3. One document = one warehouse: remove the Warehouse column from DocumentLinesGrid (all families); the header
   warehouse is the document's warehouse (label it "Warehouse", not "Default warehouse"). Lines still send
   warehouseId = header warehouse to keep the API contract.
4. Import wizard changes (shared component):
   - Always send documentTypeCode of the hosting page; template download uses the page type; preview table gets
     the "Type" column (rowDocumentTypeCode) and "On Hand" (onHandBase) and shows type-mismatch rows as Errors.
   - When the validated rows contain MORE THAN ONE warehouse, step 3 changes: instead of appending lines to the open
     document, the wizard shows the warehouse groups ("WH-001 - 12 lines, WH-002 - 3 lines") and a choice:
     "Create one document per warehouse" (calls the family's import-create endpoint with the page header +
     postImmediately from a checkbox "Post immediately", default off) or "Cancel". On success show the created
     numbers with links and navigate to the list (highlight the new rows). With a single warehouse the current
     behaviour stays (lines appended to the open document; if that warehouse differs from the header warehouse,
     ask "The file is for WH-002 - switch the document to WH-002?" and switch the header).
   - The hosting page passes the family's importCreate function (inventory now; sales/purchase later).
5. Bulk actions on every document list (shared DocumentListPage pattern): checkbox selection column (only rows the
   user may act on are selectable: drafts for Post / Delete), a selection toolbar above the grid "3 selected:
   Post selected / Delete selected / Clear", confirm dialog, then bulk-post / bulk-delete; results shown in a
   modal table (number, result badge, message) and the grid reloads. Selection survives paging within the session.
   Apply to Inventory In / Out now; the pattern must be reusable by the sales and purchase lists.
6. Item Definition: "Purchasing" section on the item page (Default Supplier: searchable Select from
   parties/lookup?type=Supplier; Lead time (days)) and read-only "Costs" info (Average cost, Last cost, Last supplier,
   Last purchase date); list gets an "Avg. Cost" column (hidden below 1024 px).
7. docs/frontend-conventions.md: "Document type configuration", "One document = one warehouse", "Bulk actions",
   "Import: one document per warehouse".
8. Quality: typecheck / lint / build clean; all breakpoints; permission gating.

VERIFY (API running) with screenshots at 1440 and 390:
  a. Configuration > Document Types lists 8 rows; editing INV_IN number length to 5 shows in the next document.
  b. Inventory In shows editable cost, Inventory Out read-only cost - driven by the config (temporarily set
     INV_OUT priceEditable = true in the config page -> the column becomes editable; set it back).
  c. Import a file with rows for WH-001 and WH-002 on Inventory In -> the wizard offers "Create one document per
     warehouse" -> 2 documents appear in the list with IN-KLW-... numbers; with "Post immediately" both are Posted.
  d. Select 3 drafts in the Inventory In list -> Post selected -> results modal (one NO_LINES failure) -> grid
     reloads with the posted ones.
  e. Item page: choose a default supplier and lead time, save, reload -> kept; Costs box shows average/last cost
     after an Inventory In is posted.
  f. Lines grid has no Warehouse column; header shows "Warehouse".
Report: files added/changed, navigation changes, every verification result.
```
