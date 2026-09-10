/* =====================================================================================
   Inventory_Shipment - 14: Sales - Import Invoice Items from Excel   (user story US-SAL-002)

   New schema: sales. This script provides the VALIDATION ENGINE and the IMPORT AUDIT LOG.
   The Excel file is parsed by the API (ClosedXML) into rows; the rows are sent here as a
   table-valued parameter and validated in ONE round trip against the master data:
   items (by Item Code or Barcode), units & packaging, warehouses of the invoice branch, and
   the Unit Price List (branch-specific price -> All Branches price).

   Objects:
     sales.tvp_InvoiceImportRow             - table type (one Excel row)
     sales.usp_InvoiceImport_Validate       - returns every row with Status Valid | Warning | Error,
                                              a message, and the RESOLVED values (item, unit,
                                              warehouse, effective price, discount, expiry)
     sales.InvoiceImportLogs                - one row per import operation (audit)
     sales.usp_InvoiceImport_Log            - writes the audit row
     sales.usp_InvoiceImport_AttachInvoice  - links log rows to the invoice once it is saved
   Permissions: sales.invoices.import (run imports), sales.invoices.priceoverride (a manual
                Unit Price in the file is accepted instead of the system price), module "Sales".

   Validation rules (spec US-SAL-002):
     - Item Code / Barcode required; item must exist and be active (barcode also fixes the unit).
     - Quantity required, whole number > 0 (pieces).
     - Unit: if given must be configured for the item (unit type name or SKU); blank = the item's
       Sales Unit (base unit when none is flagged).
     - Warehouse: if given must exist, be active and belong to the invoice branch (code or name);
       blank = invoice header default warehouse.
     - Unit Price: blank = system price (branch -> all branches); given = accepted only when
       @AllowPriceOverride = 1, otherwise the system price is used with a Warning; no system price
       and no accepted manual price = Error.
     - Discount %: blank = 0; must be between 0 and @MaxDiscountPercent.
     - Expiry Date: unparseable = Error; in the past = Warning.
     - Status precedence: any Error -> Error; else any Warning -> Warning; else Valid.
   Consolidation of identical rows (rule 16) is done by the API after validation.

   Error numbers (header problems, read by the API): 61000 validation, 61008 branch / warehouse /
   price list missing or inactive, or warehouse not in the branch.

   Requires 06 (Branches), 07 (Warehouses), 11 (Items), 12 (Price Lists / Unit Prices).
   Idempotent. NOTE: a table type cannot be ALTERed - to change it, drop the procs using it first.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL OR OBJECT_ID(N'masterdata.UnitPrices', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 07, 11 and 12 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'sales') IS NULL
    EXEC (N'CREATE SCHEMA [sales] AUTHORIZATION [dbo];');
GO

/* ------------------------------------------------------------------ 1. Table type (one Excel row) */

IF TYPE_ID(N'sales.tvp_InvoiceImportRow') IS NULL
BEGIN
    CREATE TYPE sales.tvp_InvoiceImportRow AS TABLE
    (
        RowNumber       INT            NOT NULL PRIMARY KEY,   -- Excel row number (for messages)
        ItemRef         NVARCHAR(50)   NULL,                   -- Item Code or Barcode
        UnitName        NVARCHAR(50)   NULL,                   -- unit type name or SKU; NULL = sales unit
        WarehouseRef    NVARCHAR(150)  NULL,                   -- warehouse code or name; NULL = header default
        Quantity        DECIMAL(18,3)  NULL,                   -- parsed number (NULL when not numeric)
        RawQuantity     NVARCHAR(50)   NULL,                   -- original text when parsing failed
        UnitPrice       DECIMAL(18,4)  NULL,                   -- manual price (NULL = use system price)
        DiscountPercent DECIMAL(9,4)   NULL,                   -- NULL = 0
        ExpiryDate      DATE           NULL,
        RawExpiryDate   NVARCHAR(50)   NULL,                   -- original text when parsing failed
        Notes           NVARCHAR(300)  NULL
    );
    PRINT 'Created type sales.tvp_InvoiceImportRow';
END
GO

/* ------------------------------------------------------------------ 2. Audit log */

IF OBJECT_ID(N'sales.InvoiceImportLogs', N'U') IS NULL
BEGIN
    CREATE TABLE sales.InvoiceImportLogs
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        InvoiceId      INT            NULL,          -- set when the invoice is saved (no FK yet: invoices come with US-SAL-001)
        DraftReference NVARCHAR(50)   NULL,          -- client-side draft id until the invoice exists
        BranchId       INT            NOT NULL,
        WarehouseId    INT            NOT NULL,
        PriceListId    INT            NOT NULL,
        FileName       NVARCHAR(255)  NOT NULL,
        TotalRows      INT            NOT NULL,
        ImportedRows   INT            NOT NULL,
        WarningRows    INT            NOT NULL,
        RejectedRows   INT            NOT NULL,
        ImportedBy     INT            NULL,
        ImportedAtUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_InvoiceImportLogs_ImportedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_InvoiceImportLogs PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_InvoiceImportLogs_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_InvoiceImportLogs_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_InvoiceImportLogs_PriceList FOREIGN KEY (PriceListId) REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_InvoiceImportLogs_User      FOREIGN KEY (ImportedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_InvoiceImportLogs_Invoice ON sales.InvoiceImportLogs (InvoiceId);
    PRINT 'Created sales.InvoiceImportLogs';
END
GO

/* ------------------------------------------------------------------ 3. Validation */

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT,
    @AllowPriceOverride  BIT           = 0,     -- caller holds sales.invoices.priceoverride
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,   -- from configuration
    @Rows                sales.tvp_InvoiceImportRow READONLY
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Invoice branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the invoice branch.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            -- Item by code, or by a unit barcode (which also identifies the unit).
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            -- Unit: explicit name/SKU, else the barcode's unit, else the sales unit (base when none flagged).
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END, iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            -- Warehouse: explicit code/name, else the invoice header default.
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            -- System price: branch-specific first, then All Branches (active prices only).
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               -- Errors (first one wins in the message, all block the row)
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               -- Warnings
               Warn1 = CASE WHEN x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.' END
        FROM resolved x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice ELSE j.SystemPrice END,
           PriceSource = CASE WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ------------------------------------------------------------------ 4. Audit procedures */

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Log
    @BranchId       INT,
    @WarehouseId    INT,
    @PriceListId    INT,
    @FileName       NVARCHAR(255),
    @TotalRows      INT,
    @ImportedRows   INT,
    @WarningRows    INT,
    @RejectedRows   INT,
    @DraftReference NVARCHAR(50) = NULL,
    @InvoiceId      INT          = NULL,
    @ImportedBy     INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 61000, 'File name is required.', 1;

    INSERT INTO sales.InvoiceImportLogs (InvoiceId, DraftReference, BranchId, WarehouseId, PriceListId, FileName,
                                         TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
    VALUES (@InvoiceId, @DraftReference, @BranchId, @WarehouseId, @PriceListId, LTRIM(RTRIM(@FileName)),
            ISNULL(@TotalRows, 0), ISNULL(@ImportedRows, 0), ISNULL(@WarningRows, 0), ISNULL(@RejectedRows, 0), @ImportedBy);
    SET @NewId = SCOPE_IDENTITY();
END
GO

-- Called by the invoice save (US-SAL-001) to attach the import logs of a draft to the saved invoice.
CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_AttachInvoice
    @DraftReference NVARCHAR(50),
    @InvoiceId      INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sales.InvoiceImportLogs SET InvoiceId = @InvoiceId
    WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;
END
GO

/* ------------------------------------------------------------------ 5. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'sales.invoices.import',        N'Import invoice items',  N'Sales', N'Import invoice lines from an Excel file.',                        600),
        (N'sales.invoices.priceoverride', N'Override selling price', N'Sales', N'Accept a manual unit price instead of the price list price.',   610)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code IN (N'sales.invoices.import', N'sales.invoices.priceoverride')
  AND r.IsSystem = 1
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 6. Self-test (uses the demo item when present) */

DECLARE @BranchId INT = (SELECT TOP (1) Id FROM masterdata.Branches WHERE IsMainBranch = 1 AND IsActive = 1);
DECLARE @WhId INT = (SELECT TOP (1) Id FROM masterdata.Warehouses WHERE BranchId = @BranchId AND IsActive = 1 ORDER BY IsMainWarehouse DESC);
DECLARE @PlId INT = (SELECT TOP (1) Id FROM masterdata.PriceLists WHERE IsActive = 1 ORDER BY Id);

IF @BranchId IS NOT NULL AND @WhId IS NOT NULL AND @PlId IS NOT NULL
BEGIN
    DECLARE @t sales.tvp_InvoiceImportRow;
    INSERT INTO @t (RowNumber, ItemRef, UnitName, WarehouseRef, Quantity, UnitPrice, DiscountPercent, ExpiryDate, Notes)
    VALUES (2, N'TVS-AP160', NULL, NULL, 2, NULL, 5, NULL, N'demo row'),      -- valid when a price exists
           (3, N'XYZ-999',   NULL, NULL, 1, NULL, 0, NULL, NULL),             -- item not found
           (4, N'TVS-AP160', N'Carton', NULL, 1, NULL, 0, NULL, NULL),        -- unit not configured
           (5, N'TVS-AP160', NULL, NULL, 0, NULL, 0, NULL, NULL),             -- quantity zero
           (6, N'TVS-AP160', NULL, NULL, 1, 9.99, 150, NULL, NULL);           -- manual price w/o override + discount too high

    EXEC sales.usp_InvoiceImport_Validate @BranchId = @BranchId, @DefaultWarehouseId = @WhId, @PriceListId = @PlId,
         @AllowPriceOverride = 0, @MaxDiscountPercent = 50, @Rows = @t;
END
GO

SELECT Code, Name, Module FROM security.Permissions WHERE Module = N'Sales' ORDER BY SortOrder;
PRINT 'Sales - Invoice import engine is ready.';
GO
