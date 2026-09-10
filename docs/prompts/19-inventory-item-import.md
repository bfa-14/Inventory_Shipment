# Import ITEMS from Excel (Item Definition page) — SQL + VS Code prompts

Two different imports now exist — keep them apart:

| | Invoice-lines import (script 14, prompt 17) | **Items import (script 16, this prompt)** |
|---|---|---|
| What it creates | Lines of a document, for items that already exist | **New items** (+ base unit, optional unit 2) in Item Definition |
| Where | "Import from Excel" on invoices / Inventory In-Out (preview page today) | **"Import from Excel" button on Inventory → Item Definition** |
| Template | Item Code / Barcode, Unit, Warehouse, Qty, Price… | Item Code, Name, Brand, Family, Country, Warehouse, units, SKU, barcode… |

Order: run `Database\16_Inventory_ItemImport.sql` in SSMS → Prompt A (API project open) → Prompt B (Web project open).
Sample file to test with: `docs\samples\Import_Items_Master_Sample.xlsx`.

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern: Dapper repositories over stored procedures, services returning Result with codes,
controllers with [HasPermission], PermissionCatalog, Schema.sql embedded, ClosedXML already referenced by
Inventory_Shipment.Service (invoice import, US-SAL-002). REUSE the Excel reading/writing helpers written for
InvoiceImportParser (header matching, blank-row skipping, numeric/text cell reading, error-report styling);
if they are private to that class, extract them into a shared internal ExcelHelper first - no copy/paste.

Feature: bulk CREATION of items from an Excel file, launched from the Item Definition page. Script already
written: D:\VSProjects\Inventory_Shipment\Database\16_Inventory_ItemImport.sql (read its header). It gives:
  - table type inventory.tvp_ItemImportRow, columns IN THIS ORDER (the DataTable must match it exactly):
      RowNumber INT, ItemCode, ItemName, BrandRef, Model, FamilyRef, Country, WarehouseRef, Description,
      WarrantyMonths INT, RawWarranty, MinQuantity INT, RawMin, MaxQuantity INT, RawMax, BivacText,
      BaseUnitName, BaseSku, BaseBarcode, Unit2Name, Unit2Formula INT, RawUnit2Formula, Unit2Sku, Unit2Barcode
    (Raw* = the cell text when it is not a whole number; send NULL in the INT column then).
  - inventory.usp_ItemImport_Validate(@Rows) -> per row: RowNumber, Status (Valid|Warning|Error), Message,
      ItemCode, ItemName, BrandId, BrandName, Model, ItemFamilyId, FamilyName, Country, WarehouseId,
      WarehouseName, Description, WarrantyMonths, MinQuantity, MaxQuantity, IsBivac, BaseUnitTypeId,
      BaseUnitName, BaseSku, BaseBarcode, Unit2TypeId, Unit2Name, Unit2Formula, Unit2Sku, Unit2Barcode.
  - inventory.usp_ItemImport_Commit(@Rows, @FileName, @UserId): re-validates, creates every Valid/Warning row
      (items + units) in one transaction, skips Error rows, logs to inventory.ItemImportLogs; returns TWO result
      sets: (1) LogId, TotalRows, ImportedRows, WarningRows, RejectedRows; (2) created items Id, RowNumber,
      ItemCode, ItemName, BrandName, FamilyName, WarehouseName, UnitCount.
      THROWs: 63000 (no rows) -> Validation code IMPORT_EMPTY; 63001 (every row has an error) -> Validation
      code IMPORT_ALL_ERRORS. Unique-index violations cannot happen for validated rows, but map SQL 2601/2627
      to Conflict anyway.
  - permission inventory.items.import (module Inventory, sort 435).

TASK
1. Run the script (sqlcmd -S . -E -d Inventory_Shipment -i "...\Database\16_Inventory_ItemImport.sql"), show
   its output (ends with a 4-row self-test result set: Valid / Error code exists / Error brand / Warning no
   barcode), append it to Repository\Database\Schema.sql under "-- ===== 16: Inventory - Item import =====" (no
   USE batch; keep the type creation guarded; drop the self-test and the final SELECT/PRINT).
2. Parser (Service) - class ItemImportParser, same conventions as InvoiceImportParser:
   - .xlsx only, max 10 MB, first worksheet; header row = the first row containing "Item Code"; columns matched
     by header text (case/space/punctuation-insensitive) with these aliases:
       Item Code (Code) | Item Name (Name) | Brand | Model | Family (Category) | Country (Country of Origin) |
       Default Warehouse (Warehouse) | Description | Warranty (Months) (Warranty) | Min Qty (Min Quantity,
       Minimum) | Max Qty (Max Quantity, Maximum) | BIVAC | Base Unit (Unit) | Base SKU (SKU) | Base Barcode
       (Barcode) | Unit 2 | Unit 2 Formula (Formula) | Unit 2 SKU | Unit 2 Barcode
     Mandatory headers to accept the file: Item Code, Item Name, Brand, Family, Country, Default Warehouse,
     Base Unit, Base SKU - otherwise 400 INVALID_FILE "The file does not match the items template. Download the
     template and try again." Reordered / extra columns are fine.
   - Skip blank rows; max 2000 data rows; RowNumber = Excel row number; trim strings; numeric cells or numeric
     text for Warranty / Min / Max / Unit 2 Formula (whole numbers; "12.0" is 12; otherwise NULL + Raw*);
     BIVAC cell: booleans, numbers or text passed as text (the proc accepts Yes/No/Y/N/true/false/1/0/oui/non).
     Barcodes and SKUs read as TEXT even when Excel stored them as numbers (no scientific notation, no ".0").
3. Template + error report (Service, ClosedXML):
   - GenerateItemsTemplate(): sheet "Items" with the 19 headers (bold, frozen, required ones marked with * in a
     comment and a light-yellow fill), 3 example rows (TVS-HLX150 motorcycle with PC only; BAT-12V battery with
     PC + Box formula 10; OIL-10W40 with PC, no barcode), Barcode / SKU columns formatted as Text; a sheet
     "Instructions" listing each column, required or not, accepted values and defaults (copy the Rules block of
     the script header); a sheet "Reference" with FOUR live lists read from the database: active Brands (code,
     name), active Families (code, full path name), active Warehouses (code, name, branch) and active Unit
     Types - so the user can copy exact values.
   - GenerateItemsErrorReport(rows): rows with Status <> Valid, columns Row | Item Code | Item Name | Brand |
     Family | Warehouse | Base Unit | Base SKU | Unit 2 | Status | Message (Error red, Warning orange).
4. Service IItemImportService:
   - ValidateAsync(file, userId) -> ItemImportValidationResult { fileName, totalRows, validRows, warningRows,
     errorRows, rows[] } (rows = the proc output, camelCase). No consolidation - duplicates in the file are
     reported as errors by the proc.
   - CommitAsync(file, userId) -> ItemImportCommitResult { logId, totalRows, importedRows, warningRows,
     rejectedRows, items[] { id, rowNumber, itemCode, itemName, brandName, familyName, warehouseName,
     unitCount } } via usp_ItemImport_Commit (QueryMultiple). The file is parsed again on commit (stateless,
     no server-side session); the wizard sends the same file twice.
5. API ItemImportController route api/inventory/items/import, all [HasPermission(inventory.items.import)]:
     GET  template                        -> xlsx "Items_Import_Template.xlsx"
     POST validate (multipart: file)      -> ItemImportValidationResult
     POST commit   (multipart: file)      -> ItemImportCommitResult  (201 is not needed - 200 with the result)
     POST error-report (JSON: the rows)   -> xlsx "Items_Import_Errors.xlsx"
   Problem details: INVALID_FILE (400) for wrong type / size / template, IMPORT_EMPTY and IMPORT_ALL_ERRORS
   (400, message from the proc). Log every commit at Information level: user, file, counts.
6. PermissionCatalog: inventory.items.import ("Import items from Excel"), module Inventory, sort 435.
7. Build 0 warnings; API starts with "Database schema verified".

VERIFY (token admin / Admin@12345) and show output:
  a. GET template -> valid xlsx: sheets Items / Instructions / Reference, 19 headers, 3 example rows, Reference
     lists contain TVS, FAM-001..., WH-001, PC/Box/Pallet/Container.
  b. Build a test file with the self-test rows of the script (TVS-HLX150 valid; TVS-AP160 = code exists; BAT-12V
     brand Exide unknown; OIL-10W40 without barcode) + one row with Unit 2 "Box" formula "ten" + one blank row.
     POST validate -> totalRows 5 (blank ignored), validRows 1, warningRows 1, errorRows 3 with the expected
     messages (row 6: "Unit 2 Formula 'ten' is not a whole number.").
  c. POST commit with the same file -> importedRows 2, rejectedRows 3, items[] = TVS-HLX150 (unitCount 1) and
     OIL-10W40 (unitCount 1); GET api/inventory/items/{id} for TVS-HLX150 shows brand TVS, family Motorcycles,
     warehouse WH-001, BIVAC true, one base unit PC with SKU HLX150-PC and barcode 8901234500011 flagged
     Sales + Purchase + Base; SELECT from inventory.ItemImportLogs shows the row.
  d. POST commit again with the same file -> the two created codes are now "already exists" errors, so every
     row has an error -> 400 IMPORT_ALL_ERRORS and nothing is created (item count unchanged).
  e. Fix the file so BAT-12V uses brand TVS and Unit 2 Box formula 10 -> commit creates it with unitCount 2:
     base PC (Sales + Base), Box (Purchase, formula 10, SKU BAT12-BOX).
  f. A .csv or a 12 MB file -> 400 INVALID_FILE; a file without the "Base SKU" column -> 400 INVALID_FILE with
     the template message.
Report: script output, files changed, every verification result.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md,
shared ui components, responsive at 390/768/1024/1440). Frontend only. Backend exists:
api/inventory/items/import: GET template (xlsx), POST validate (multipart: file) -> { fileName, totalRows,
validRows, warningRows, errorRows, rows[] } with rows { rowNumber, status: 'Valid'|'Warning'|'Error', message,
itemCode, itemName, brandName, model, familyName, country, warehouseName, description, warrantyMonths,
minQuantity, maxQuantity, isBivac, baseUnitName, baseSku, baseBarcode, unit2Name, unit2Formula, unit2Sku,
unit2Barcode }, POST commit (multipart: file) -> { logId, totalRows, importedRows, warningRows, rejectedRows,
items[] { id, rowNumber, itemCode, itemName, brandName, familyName, warehouseName, unitCount } },
POST error-report (rows) -> xlsx. Problem-detail codes: INVALID_FILE, IMPORT_EMPTY, IMPORT_ALL_ERRORS.
Permission: inventory.items.import. Dev: npm run dev, admin / Admin@12345.

Feature: "Import from Excel" on the Item Definition page (Inventory > Item Definition, /inventory/items) that
CREATES items in bulk. Reuse the invoice wizard (src/components/sales/ImportInvoiceItemsWizard.tsx) - do not
build a second wizard from scratch:

TASK
1. Extract the wizard SHELL into src/components/import/ExcelImportWizard.tsx: Modal (xl, fullScreen < 768),
   3-step Stepper (Upload File / Validate & Preview / Import), template download button + info Alert, Dropzone
   (.xlsx, 10 MB, client-side messages), the four summary cards, the preview DataTable with status filter chips
   (All / Valid / Warnings / Errors), Download Error File, the import step with progress + success / all-errors
   panels, Esc confirmation after a validation with unimported rows. It is generic through props:
     { opened, onClose, title, templateFileName, alertText, downloadTemplate(): Promise<Blob>,
       validate(file): Promise<ValidationResult<TRow>>, commit(file, rows): Promise<CommitResult>,
       errorReport(rows): Promise<Blob>, columns: DataTableColumn<TRow>[] (the preview columns, the shell adds
       #, Status and Message itself), importButtonLabel(n) e.g. "Create N Items", successText(result) }.
   Make ImportInvoiceItemsWizard a thin wrapper over the shell with IDENTICAL behaviour and props as today
   (its "commit" is the existing client-side onImported + POST log). Re-test the preview page after the refactor.
2. src/api/inventory/itemImport.ts: template / validate / commit / errorReport (FormData helper, blob helper).
3. src/components/inventory/ImportItemsWizard.tsx using the shell: title "Import Items from Excel", alert
   "Use the items template. Brand, Family and Warehouse accept the code or the name; the Reference sheet of the
   template lists the valid values.", preview columns: Item Code, Item Name, Brand, Family, Warehouse, Base
   Unit, Base SKU, Barcode, Unit 2 (e.g. "Box x10"), BIVAC (Yes/No badge); import button "Create N Items"
   (N = Valid + Warning; when errors exist add "(E rows with errors will be skipped)"); commit = POST commit
   with the same file; success text "N items created. W row(s) with warnings were created too. E row(s) with
   errors were skipped - download the error file, fix them and import again."; IMPORT_ALL_ERRORS shows the
   all-errors panel. After a successful commit call onImported(items) and refresh the Items list on close.
4. Item Definition list page: add an "Import from Excel" button (IconFileSpreadsheet) next to "+ New Item",
   visible only with inventory.items.import; on mobile it collapses into the header's overflow/secondary
   actions like the other pages. After the wizard closes with imports: reload the grid, show
   notify.success("N items created") and, when the result has 1..20 items, highlight them (selected-row
   colour) on the first page filtered by search "" sorted by CreatedAt desc if such a sort exists - otherwise
   just reload.
5. Navigation: rename the Sales preview entry "Import Items (preview)" to "Import Invoice Lines (preview)"
   so the two imports are not confused; add a one-line info Alert on that page saying items themselves are
   imported from Item Definition > Import from Excel.
6. docs/frontend-conventions.md: add "Excel import wizard shell" (props, how to add a third import in
   10 lines).
7. Quality: typecheck / lint / build clean; all breakpoints; a user without inventory.items.import sees no
   button (and the invoice preview page is unchanged for a user who only has sales.invoices.import).

VERIFY (API running) with screenshots at 1440 and 390 of each step:
  a. Item Definition > Import from Excel > Download Template saves Items_Import_Template.xlsx (3 sheets).
  b. Upload docs/samples/Import_Items_Master_Sample.xlsx (in the API repo) -> summary Total 6 / Valid 2 /
     Warnings 1 / Errors 3, badges and messages per row, chips filter, Download Error File works.
  c. Create 3 Items -> progress -> success text with the right counts -> list reloads and shows TVS-HLX150,
     OIL-10W40 and BAT-12V; opening BAT-12V shows units PC (base) and Box x10.
  d. Import the same file again -> the created codes are now errors ("already exists"); with every row in
     error the all-errors panel appears and nothing is created.
  e. Invoice preview page still works exactly as before the refactor (validate + import valid rows).
Report: files added/changed, navigation change, every verification result.
```
