# US-SAL-002 — Import Invoice Items from Excel — SQL + VS Code prompts

Run order: `Database\14_Sales_InvoiceImport.sql` in SSMS (needs 07, 11, 12) → Prompt A → Prompt B.

Built as a self-contained engine so it plugs into the Sales Invoice page (US-SAL-001) when that page
exists: the database validates the rows against master data in one call (items by code/barcode, units,
branch warehouses, unit prices with branch → all-branches fallback), the API parses the Excel with
ClosedXML and exposes template / validate / log endpoints, and the frontend wizard is a reusable
component that returns the imported lines to its host page (tested now on a small sandbox page).

Permissions (module Sales): `sales.invoices.import`, `sales.invoices.priceoverride`. Header errors:
61000 `VALIDATION`, 61008 `MASTER_INACTIVE`. Row statuses: Valid / Warning / Error with row-level messages.

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern: Dapper repositories over stored procedures, services returning Result with codes,
controllers with [HasPermission], PermissionCatalog, Schema.sql embedded. EXCEPTION for this task: add the
NuGet package ClosedXML (latest stable, MIT) to Inventory_Shipment.Service for reading/writing .xlsx.

Feature: US-SAL-002 Import Invoice Items from Excel - the import ENGINE (no invoice page yet; US-SAL-001 will
host it). Script already written: D:\VSProjects\Inventory_Shipment\Database\14_Sales_InvoiceImport.sql (read
its header): schema sales; table type sales.tvp_InvoiceImportRow (RowNumber, ItemRef, UnitName, WarehouseRef,
Quantity DECIMAL, RawQuantity, UnitPrice, DiscountPercent, ExpiryDate DATE, RawExpiryDate, Notes);
sales.usp_InvoiceImport_Validate(@BranchId, @DefaultWarehouseId, @PriceListId, @AllowPriceOverride,
@MaxDiscountPercent, @Rows TVP) -> per row: RowNumber, Status (Valid|Warning|Error), Message, ItemRef, ItemId,
ItemCode, ItemName, ItemUnitId, UnitTypeName, PackingFormula, WarehouseId, WarehouseCode, WarehouseName,
Quantity INT, UnitPrice (effective), PriceSource (Manual|Branch|AllBranches), ManualPrice, DiscountPercent,
ExpiryDate, Notes; sales.usp_InvoiceImport_Log(...) -> audit row id; sales.usp_InvoiceImport_AttachInvoice.
Header THROWs: 61000 -> Validation, 61008 -> Validation MASTER_INACTIVE.

TASK
1. Run the script (sqlcmd -S . -E -d Inventory_Shipment -i "...\Database\14_Sales_InvoiceImport.sql"), show its
   output (it ends with a self-test result set), append it to Repository\Database\Schema.sql under
   "-- ===== 14: Sales - Invoice import =====" (no USE batch; keep the type creation guarded; drop the self-test
   and the final SELECT/PRINT).
2. Excel parsing (Service, ClosedXML) - class InvoiceImportParser:
   - Accept .xlsx only, max 10 MB, first worksheet; header row = the first row containing "Item Code" (the
     template header is: Item Code / Barcode | Unit | Warehouse | Quantity | Unit Price | Discount % |
     Expiry Date | Notes); match columns by header text (case/space-insensitive), tolerate reordered columns;
     reject the file with a clear message when the mandatory columns Item Code / Barcode and Quantity are missing
     ("The file does not match the import template. Download the template and try again.").
   - Skip blank rows (all cells empty). Max 2000 data rows. RowNumber = the Excel row number.
   - Quantity / Unit Price / Discount %: numeric cells or numeric text (accept "5%" for discount); when not
     parseable send NULL + Raw* text. Expiry Date: Excel date cells or text in dd/MM/yyyy, yyyy-MM-dd; else
     NULL + RawExpiryDate. Trim all strings.
3. Template + error report (Service, ClosedXML):
   - GenerateTemplate(): sheet "Invoice Items" with the 8 headers (bold, frozen), 3 example rows as in the spec
     (OIL-001 / BAT-001 / SPK-001), date column formatted dd/MM/yyyy, and a second sheet "Instructions"
     listing each column, required or not, and its default behaviour.
   - GenerateErrorReport(rows): the validated rows with Status <> Valid, columns Row | Item Code / Barcode |
     Unit | Warehouse | Quantity | Unit Price | Discount % | Expiry Date | Status | Message (Error rows red,
     Warning rows orange).
4. Service IInvoiceImportService:
   - ValidateAsync(file, branchId, warehouseId, priceListId (nullable), userId, userPermissions) -> ImportValidationResult
     { fileName, totalRows, validRows, warningRows, errorRows, rows[] } where AllowPriceOverride = user holds
     sales.invoices.priceoverride, MaxDiscountPercent from configuration "Sales:MaxDiscountPercent" (default 100,
     add to appsettings.json), rows come from usp_InvoiceImport_Validate via the TVP (Dapper: use
     SqlMapper.AsTableValuedParameter or a DataTable with the type name sales.tvp_InvoiceImportRow).
   - Consolidation (spec rule 16), applied AFTER validation to Valid/Warning rows only: rows with identical
     ItemUnitId + WarehouseId + UnitPrice + DiscountPercent + ExpiryDate + Notes are merged into the first one
     (quantities summed) and the merged row gets Status Warning with message "Merged with row(s) 7, 9"; the
     absorbed rows are returned with Status "Merged" (not imported, not counted as errors).
   - LogAsync(request) -> id: writes the audit row (usp_InvoiceImport_Log).
5. API InvoiceImportController route api/sales/invoice-import:
     GET  template                         [HasPermission(sales.invoices.import)] -> xlsx file "Invoice_Items_Template.xlsx"
     POST validate (multipart: file, branchId, warehouseId, priceListId OPTIONAL) [import] -> ImportValidationResult
          (priceListId omitted = STOCK MODE for Inventory In/Out: pass NULL to the proc, no pricing checks, the
          Unit Price column is taken as the unit cost when present - script 15 already updated the proc for this)
     POST error-report (JSON: the rows)    [import] -> xlsx "Invoice_Import_Errors.xlsx"
     POST log (JSON: branchId, warehouseId, priceListId, fileName, totalRows, importedRows, warningRows,
               rejectedRows, draftReference) [import] -> { id }
   Return RFC 9457 problem details for a file that is not .xlsx / too large / not matching the template
   (400, code INVALID_FILE) and for header problems (MASTER_INACTIVE).
6. PermissionCatalog: sales.invoices.import ("Import invoice items") and sales.invoices.priceoverride
   ("Override selling price"), NEW module "Sales", sort 600/610.
7. Build 0 warnings; API starts with "Database schema verified".

VERIFY (token admin / Admin@12345; admin holds both permissions - create a second user WITHOUT priceoverride
for one check) and show output:
  a. GET template -> a valid xlsx (open it with ClosedXML in a quick check: 8 headers, 3 example rows).
  b. Build a test file with rows: TVS-AP160 qty 2 (blank price); TVS-AP160 unit "Carton"; XYZ-999; TVS-AP160
     qty 0; TVS-AP160 price 9.99 discount 150; TVS-AP160 qty 3 (duplicate context of row 1); a blank row.
     POST validate -> totals: rows 6 (blank ignored), row 1 Valid with PriceSource Branch/AllBranches (or Error
     "No selling price" if no demo price exists - then add one via usp_UnitPrice_Create and re-run), row 2 Error
     unit not configured, row 3 Error does not exist, row 4 Error quantity, row 5 Error discount range (and with
     the no-override user, price 9.99 within range -> Warning "Manual price ignored"), row 6 Merged into row 1
     (row 1 becomes Warning "Merged with row(s) 7", quantity 5).
  c. POST error-report with those rows -> xlsx containing the non-valid rows.
  d. POST log -> id; SELECT from sales.InvoiceImportLogs shows the row.
  e. A .csv or a 12 MB file -> 400 INVALID_FILE; a wrong price list id -> 400 MASTER_INACTIVE.
Report: script output, package added, files changed, every verification result.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md,
shared ui components, responsive at 390/768/1024/1440). Frontend only. Backend exists:
api/sales/invoice-import: GET template (xlsx), POST validate (multipart: file, branchId, warehouseId,
priceListId) -> { fileName, totalRows, validRows, warningRows, errorRows, rows[] } with rows { rowNumber,
status: 'Valid'|'Warning'|'Error'|'Merged', message, itemRef, itemId, itemCode, itemName, itemUnitId,
unitTypeName, packingFormula, warehouseId, warehouseCode, warehouseName, quantity, unitPrice, priceSource,
manualPrice, discountPercent, expiryDate, notes }, POST error-report (rows) -> xlsx, POST log -> { id }.
Lookups: branches/lookup, warehouses/lookup?branchId=, price-lists/lookup. Permissions:
sales.invoices.import, sales.invoices.priceoverride. Dev: npm run dev, admin / Admin@12345.

Feature: US-SAL-002 - a REUSABLE import wizard. The Sales Invoice page (US-SAL-001) does not exist yet, so:
build the wizard as a component, plus a small sandbox host page to test it now. When the invoice page is built
later it will simply render <ImportInvoiceItemsWizard .../> from its "Import from Excel" button.

TASK
1. src/api/sales/invoiceImport.ts: typed functions; uploads via the existing FormData helper in http.ts;
   downloads (template, error report) via the authenticated blob helper -> browser save.
2. src/components/sales/ImportInvoiceItemsWizard.tsx - props: { opened, onClose, header: { branchId,
   warehouseId, priceListId: number | null, currencyCode, decimalPlaces }, mode: 'invoice' | 'stock',
   draftReference, onImported(lines: ImportedLine[]) }. In 'stock' mode (Inventory In/Out): no priceListId is
   sent, the price column is labelled "Unit Cost", the Discount column is hidden, and the template download
   button text says "Download Template" as well (same template).
   A Modal (size xl, fullScreen below 768 px) with a 3-step Stepper exactly like the customer figure:
   Step 1 "Upload File": info Alert "Use the standard template to ensure your file is imported correctly" with
     a "Download Template" button; a Dropzone (drag & drop or Browse, .xlsx only, max 10 MB - client-side
     checks with clear messages) showing the selected file name + size and an X to remove; footer Cancel /
     "Validate File" (disabled until a file is chosen, loading while validating).
   Step 2 "Validate & Preview": four summary cards (Total Rows, Valid Rows green, Warning Rows orange,
     Error Rows red) and the preview table (#, Item Code, Item Name, Unit, Warehouse, Qty, Price formatted with
     the price list currency, Discount %, Status badge Valid/Warning/Error/Merged, Message) - client-side
     status filter chips (All / Valid / Warnings / Errors), sticky header, horizontal scroll on mobile; footer
     Cancel / "Download Error File" (when errors or warnings exist) / "Import Valid Rows (N)" where N = Valid +
     Warning rows (disabled when N = 0). Never import silently: when errors exist the button text says how many
     rows will be skipped.
   Step 3 "Import": progress (Loader + "Importing valid rows... x / N" animated over the rows list), then a
     success Alert "N items imported successfully. W row(s) with warning and E row(s) with error were not
     imported." (Merged rows are counted inside their target row). On confirm the wizard POSTs the audit log
     (fileName, counts, draftReference) and calls onImported with the Valid + Warning rows mapped to
     ImportedLine { itemId, itemCode, itemName, itemUnitId, unitTypeName, packingFormula, warehouseId,
     warehouseCode, quantity, unitPrice, discountPercent, expiryDate, notes, importRowNumber }; "Close" closes.
   Optional step 3 variant when NO row is valid: the error panel from the figure ("N row(s) contain errors and
   were not imported - please correct the errors in your Excel file and try again") with Download Error File.
   Esc/close asks for confirmation only after a successful validation with unimported rows.
3. Sandbox host page (temporary, so the wizard can be tested before US-SAL-001): route
   /sales/import-preview under a new "Sales" section in navigation.ts (label "Import Items (preview)",
   permission sales.invoices.import, badge "Preview"). Content: a header card with Branch (Select), Default
   Warehouse (Select filtered by branch), Price List (Select, shows currency) and an "Import from Excel"
   button; below it a plain editable lines grid (Item, Unit, Warehouse, Qty, Price, Discount %, Line total =
   qty x price x (1 - discount/100), Notes) filled by onImported (append), with a Totals footer (Subtotal,
   Total discount, Grand total in the price list currency). No saving - it only proves the wizard works.
   Mark the page with an info Alert "Preview page - the wizard will move to the Sales Invoice screen".
4. docs/frontend-conventions.md: add a "Sales import wizard" section (props, ImportedLine shape, how the
   invoice page must use it: pass the header, append lines, store draftReference for the audit link).
5. Quality: typecheck / lint / build clean; all breakpoints; a user without sales.invoices.import sees neither
   the menu item nor the button.

VERIFY (API running) with screenshots at 1440 and 390 of each step:
  a. Download Template saves Invoice_Items_Template.xlsx.
  b. Upload a file with the verification rows from Prompt A -> summary counts match, badges/messages per row,
     filter chips work, Download Error File saves the xlsx.
  c. Import Valid Rows -> progress -> success message with the right counts; lines appear in the sandbox grid
     with prices in the price list currency and totals computed; the audit row exists in sales.InvoiceImportLogs.
  d. A .csv and a 12 MB file are refused client-side; a file without the template headers shows the API's
     "does not match the import template" message.
  e. Cancel on step 2 after validation asks for confirmation.
Report: files added/changed, navigation changes, every verification result.
```
