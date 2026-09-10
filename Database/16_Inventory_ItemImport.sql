/* =====================================================================================
   Inventory_Shipment - 16: Import ITEMS from Excel (Item Definition page)

   Bulk CREATION of items (with their base unit and an optional second unit) from a sheet.
   Same 3-step wizard as the invoice-lines import, different template and rules.
   The existing wizard (script 14) imports LINES for items that already exist; this one
   creates the items themselves.

   Objects (schema inventory):
     tvp_ItemImportRow        - one Excel row (raw text kept for unparseable numbers)
     usp_ItemImport_Validate  - resolves Brand / Family / Warehouse by CODE or NAME and unit types by
                                name; returns every row with Status Valid | Warning | Error + Message
     usp_ItemImport_Commit    - re-validates and creates ALL Valid/Warning rows (items + units) in ONE
                                transaction; Error rows are skipped; logs; returns summary + created items
     ItemImportLogs           - audit of every commit
   Permission: inventory.items.import (module Inventory, sort 435).

   Template columns (header row; order free, matched by name by the API):
     Item Code* | Item Name* | Brand* | Model | Family* | Country* | Default Warehouse* | Description |
     Warranty (Months) | Min Qty | Max Qty | BIVAC | Base Unit* | Base SKU* | Base Barcode |
     Unit 2 | Unit 2 Formula | Unit 2 SKU | Unit 2 Barcode                    (* = required)
   Rules:
     - Item Code unique (existing codes are REJECTED - the import never edits items) and unique in the file.
     - Brand / Family / Default Warehouse: code or name, must exist and be active.
     - Country: ISO 3166-1 alpha-2 (IN, CD, ...).  BIVAC: Yes/No (also Y/N, true/false, 1/0, oui/non).
     - Base Unit: a Unit Type name (PC, Box, ...), formula 1, Base SKU required, barcode optional but
       unique system-wide and in the file.
     - Unit 2 (optional): another Unit Type, whole-number formula >= 2 (base units per unit 2), its own SKU.
     - Flags: base unit = Sales unit (+ Purchase unit when there is no Unit 2); Unit 2 = Purchase unit.
       (Adjust in Item Definition afterwards.)
     - Warning (row still imported): base unit without barcode.

   Error numbers: 63000 file has no rows, 63001 every row has an error (nothing imported).
   Requires 07, 09, 10, 11. Idempotent. A table type cannot be ALTERed - drop the procs first.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL OR OBJECT_ID(N'masterdata.Brands', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.ItemFamilies', N'U') IS NULL OR OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 07, 09, 10 and 11 before this script.', 16, 1);
    RETURN;
END
GO

/* ------------------------------------------------------------------ 1. Table type */

IF TYPE_ID(N'inventory.tvp_ItemImportRow') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ItemImportRow AS TABLE
    (
        RowNumber       INT            NOT NULL PRIMARY KEY,   -- Excel row number (header = 1)
        ItemCode        NVARCHAR(50)   NULL,
        ItemName        NVARCHAR(200)  NULL,
        BrandRef        NVARCHAR(150)  NULL,   -- brand code or name
        Model           NVARCHAR(100)  NULL,
        FamilyRef       NVARCHAR(150)  NULL,   -- family code or name
        Country         NVARCHAR(10)   NULL,   -- ISO alpha-2
        WarehouseRef    NVARCHAR(150)  NULL,   -- warehouse code or name
        Description     NVARCHAR(1000) NULL,
        WarrantyMonths  INT            NULL,   RawWarranty     NVARCHAR(50) NULL,   -- Raw* = cell text when not numeric
        MinQuantity     INT            NULL,   RawMin          NVARCHAR(50) NULL,
        MaxQuantity     INT            NULL,   RawMax          NVARCHAR(50) NULL,
        BivacText       NVARCHAR(10)   NULL,
        BaseUnitName    NVARCHAR(50)   NULL,
        BaseSku         NVARCHAR(50)   NULL,
        BaseBarcode     NVARCHAR(50)   NULL,
        Unit2Name       NVARCHAR(50)   NULL,
        Unit2Formula    INT            NULL,   RawUnit2Formula NVARCHAR(50) NULL,
        Unit2Sku        NVARCHAR(50)   NULL,
        Unit2Barcode    NVARCHAR(50)   NULL
    );
    PRINT 'Created type inventory.tvp_ItemImportRow';
END
GO

/* ------------------------------------------------------------------ 2. Audit log */

IF OBJECT_ID(N'inventory.ItemImportLogs', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ItemImportLogs
    (
        Id            INT IDENTITY(1,1) NOT NULL,
        FileName      NVARCHAR(255) NOT NULL,
        TotalRows     INT           NOT NULL,
        ImportedRows  INT           NOT NULL,
        WarningRows   INT           NOT NULL,
        RejectedRows  INT           NOT NULL,
        ImportedBy    INT           NULL,
        ImportedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_ItemImportLogs_At DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ItemImportLogs PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ItemImportLogs_User FOREIGN KEY (ImportedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created inventory.ItemImportLogs';
END
GO

/* ------------------------------------------------------------------ 3. Validate */

CREATE OR ALTER PROCEDURE inventory.usp_ItemImport_Validate
    @Rows inventory.tvp_ItemImportRow READONLY
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH r AS
    (
        SELECT RowNumber,
               ItemCode     = NULLIF(LTRIM(RTRIM(ItemCode)), N''),
               ItemName     = NULLIF(LTRIM(RTRIM(ItemName)), N''),
               BrandRef     = NULLIF(LTRIM(RTRIM(BrandRef)), N''),
               Model        = NULLIF(LTRIM(RTRIM(Model)), N''),
               FamilyRef    = NULLIF(LTRIM(RTRIM(FamilyRef)), N''),
               Country      = NULLIF(UPPER(LTRIM(RTRIM(Country))), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(WarehouseRef)), N''),
               Description  = NULLIF(LTRIM(RTRIM(Description)), N''),
               WarrantyMonths, RawWarranty, MinQuantity, RawMin, MaxQuantity, RawMax,
               BivacText    = NULLIF(UPPER(LTRIM(RTRIM(BivacText))), N''),
               BaseUnitName = NULLIF(LTRIM(RTRIM(BaseUnitName)), N''),
               BaseSku      = NULLIF(LTRIM(RTRIM(BaseSku)), N''),
               BaseBarcode  = NULLIF(LTRIM(RTRIM(BaseBarcode)), N''),
               Unit2Name    = NULLIF(LTRIM(RTRIM(Unit2Name)), N''),
               Unit2Formula, RawUnit2Formula,
               Unit2Sku     = NULLIF(LTRIM(RTRIM(Unit2Sku)), N''),
               Unit2Barcode = NULLIF(LTRIM(RTRIM(Unit2Barcode)), N'')
        FROM @Rows
    ),
    resolved AS
    (
        SELECT r.*,
               b.Id  AS BrandId,        b.BrandName,       b.IsActive AS BrandActive,
               f.Id  AS ItemFamilyId,   f.FamilyName,      f.IsActive AS FamilyActive,
               w.Id  AS WarehouseId,    w.WarehouseName,   w.IsActive AS WarehouseActive,
               bu.Id AS BaseUnitTypeId, bu.IsActive AS BaseUnitActive,
               u2.Id AS Unit2TypeId,    u2.IsActive AS Unit2Active,
               IsBivac = CASE WHEN r.BivacText IN (N'YES', N'Y', N'TRUE', N'1', N'OUI') THEN CAST(1 AS BIT)
                              WHEN r.BivacText IS NULL OR r.BivacText IN (N'NO', N'N', N'FALSE', N'0', N'NON') THEN CAST(0 AS BIT) END,
               CodeDupInFile = (SELECT COUNT(*) FROM r r2 WHERE r2.ItemCode = r.ItemCode) - 1,
               BaseBarcodeDupInFile = CASE WHEN r.BaseBarcode IS NULL THEN 0 ELSE
                    (SELECT COUNT(*) FROM r r2 WHERE r2.RowNumber <> r.RowNumber AND (r2.BaseBarcode = r.BaseBarcode OR r2.Unit2Barcode = r.BaseBarcode)) END,
               Unit2BarcodeDupInFile = CASE WHEN r.Unit2Barcode IS NULL THEN 0 ELSE
                    (SELECT COUNT(*) FROM r r2 WHERE r2.RowNumber <> r.RowNumber AND (r2.BaseBarcode = r.Unit2Barcode OR r2.Unit2Barcode = r.Unit2Barcode)) END
        FROM r
        OUTER APPLY (SELECT TOP (1) Id, BrandName, IsActive FROM masterdata.Brands
                     WHERE BrandCode = r.BrandRef OR BrandName = r.BrandRef
                     ORDER BY CASE WHEN BrandCode = r.BrandRef THEN 0 ELSE 1 END) b
        OUTER APPLY (SELECT TOP (1) Id, FamilyName, IsActive FROM masterdata.ItemFamilies
                     WHERE FamilyCode = r.FamilyRef OR FamilyName = r.FamilyRef
                     ORDER BY CASE WHEN FamilyCode = r.FamilyRef THEN 0 ELSE 1 END) f
        OUTER APPLY (SELECT TOP (1) Id, WarehouseName, IsActive FROM masterdata.Warehouses
                     WHERE WarehouseCode = r.WarehouseRef OR WarehouseName = r.WarehouseRef
                     ORDER BY CASE WHEN WarehouseCode = r.WarehouseRef THEN 0 ELSE 1 END) w
        OUTER APPLY (SELECT TOP (1) Id, IsActive FROM masterdata.UnitTypes WHERE UnitTypeName = r.BaseUnitName) bu
        OUTER APPLY (SELECT TOP (1) Id, IsActive FROM masterdata.UnitTypes WHERE UnitTypeName = r.Unit2Name) u2
    ),
    judged AS
    (
        SELECT x.*,
               E1 = CASE WHEN x.ItemCode IS NULL THEN N'Item Code is required.'
                         WHEN LEN(x.ItemCode) > 30 THEN N'Item Code is longer than 30 characters.'
                         WHEN EXISTS (SELECT 1 FROM inventory.Items i WHERE i.ItemCode = x.ItemCode) THEN N'Item Code ' + x.ItemCode + N' already exists.'
                         WHEN x.CodeDupInFile > 0 THEN N'Item Code ' + x.ItemCode + N' appears more than once in the file.' END,
               E2 = CASE WHEN x.ItemName IS NULL THEN N'Item Name is required.' END,
               E3 = CASE WHEN x.BrandRef IS NULL THEN N'Brand is required.'
                         WHEN x.BrandId IS NULL THEN N'Brand ''' + x.BrandRef + N''' does not exist.'
                         WHEN x.BrandActive = 0 THEN N'Brand ''' + x.BrandRef + N''' is inactive.' END,
               E4 = CASE WHEN x.FamilyRef IS NULL THEN N'Family is required.'
                         WHEN x.ItemFamilyId IS NULL THEN N'Family ''' + x.FamilyRef + N''' does not exist.'
                         WHEN x.FamilyActive = 0 THEN N'Family ''' + x.FamilyRef + N''' is inactive.' END,
               E5 = CASE WHEN x.Country IS NULL THEN N'Country is required (2-letter ISO code).'
                         WHEN LEN(x.Country) <> 2 OR x.Country LIKE N'%[^A-Z]%' THEN N'Country ''' + x.Country + N''' must be a 2-letter ISO code.' END,
               E6 = CASE WHEN x.WarehouseRef IS NULL THEN N'Default Warehouse is required.'
                         WHEN x.WarehouseId IS NULL THEN N'Warehouse ''' + x.WarehouseRef + N''' does not exist.'
                         WHEN x.WarehouseActive = 0 THEN N'Warehouse ''' + x.WarehouseRef + N''' is inactive.' END,
               E7 = CASE WHEN x.RawWarranty IS NOT NULL AND x.WarrantyMonths IS NULL THEN N'Warranty ''' + x.RawWarranty + N''' is not a whole number.'
                         WHEN x.WarrantyMonths < 0 THEN N'Warranty cannot be negative.'
                         WHEN x.RawMin IS NOT NULL AND x.MinQuantity IS NULL THEN N'Min Qty ''' + x.RawMin + N''' is not a whole number.'
                         WHEN x.RawMax IS NOT NULL AND x.MaxQuantity IS NULL THEN N'Max Qty ''' + x.RawMax + N''' is not a whole number.'
                         WHEN ISNULL(x.MinQuantity, 0) < 0 OR x.MaxQuantity < 0 THEN N'Quantities cannot be negative.'
                         WHEN x.MaxQuantity IS NOT NULL AND ISNULL(x.MinQuantity, 0) > x.MaxQuantity THEN N'Min Qty cannot exceed Max Qty.' END,
               E8 = CASE WHEN x.IsBivac IS NULL THEN N'BIVAC must be Yes or No.' END,
               E9 = CASE WHEN x.BaseUnitName IS NULL THEN N'Base Unit is required (e.g. PC).'
                         WHEN x.BaseUnitTypeId IS NULL THEN N'Unit type ''' + x.BaseUnitName + N''' does not exist (Master Data > Unit Types).'
                         WHEN x.BaseUnitActive = 0 THEN N'Unit type ''' + x.BaseUnitName + N''' is inactive.'
                         WHEN x.BaseSku IS NULL THEN N'Base SKU is required.'
                         WHEN x.BaseBarcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.Barcode = x.BaseBarcode) THEN N'Barcode ' + x.BaseBarcode + N' is already used by another item.'
                         WHEN x.BaseBarcodeDupInFile > 0 THEN N'Barcode ' + x.BaseBarcode + N' appears more than once in the file.' END,
               E10 = CASE WHEN x.Unit2Name IS NULL AND (x.Unit2Sku IS NOT NULL OR x.Unit2Formula IS NOT NULL OR x.RawUnit2Formula IS NOT NULL OR x.Unit2Barcode IS NOT NULL) THEN N'Unit 2 name is missing.'
                          WHEN x.Unit2Name IS NULL THEN NULL
                          WHEN x.Unit2TypeId IS NULL THEN N'Unit type ''' + x.Unit2Name + N''' does not exist.'
                          WHEN x.Unit2Active = 0 THEN N'Unit type ''' + x.Unit2Name + N''' is inactive.'
                          WHEN x.Unit2TypeId = x.BaseUnitTypeId THEN N'Unit 2 must differ from the Base Unit.'
                          WHEN x.RawUnit2Formula IS NOT NULL AND x.Unit2Formula IS NULL THEN N'Unit 2 Formula ''' + x.RawUnit2Formula + N''' is not a whole number.'
                          WHEN ISNULL(x.Unit2Formula, 0) < 2 THEN N'Unit 2 Formula must be a whole number of at least 2 (base units per Unit 2).'
                          WHEN x.Unit2Sku IS NULL THEN N'Unit 2 SKU is required.'
                          WHEN x.Unit2Sku = x.BaseSku THEN N'Unit 2 SKU must differ from the Base SKU.'
                          WHEN x.Unit2Barcode IS NOT NULL AND x.Unit2Barcode = x.BaseBarcode THEN N'Unit 2 Barcode must differ from the Base Barcode.'
                          WHEN x.Unit2Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.Barcode = x.Unit2Barcode) THEN N'Barcode ' + x.Unit2Barcode + N' is already used by another item.'
                          WHEN x.Unit2BarcodeDupInFile > 0 THEN N'Barcode ' + x.Unit2Barcode + N' appears more than once in the file.' END,
               W1 = CASE WHEN x.BaseBarcode IS NULL THEN N'No barcode - the item cannot be scanned.' END
        FROM resolved x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.E1, j.E2, j.E3, j.E4, j.E5, j.E6, j.E7, j.E8, j.E9, j.E10) IS NOT NULL THEN N'Error'
                          WHEN j.W1 IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(RTRIM(CONCAT(ISNULL(j.E1 + N' ', N''), ISNULL(j.E2 + N' ', N''), ISNULL(j.E3 + N' ', N''), ISNULL(j.E4 + N' ', N''),
                                         ISNULL(j.E5 + N' ', N''), ISNULL(j.E6 + N' ', N''), ISNULL(j.E7 + N' ', N''), ISNULL(j.E8 + N' ', N''),
                                         ISNULL(j.E9 + N' ', N''), ISNULL(j.E10 + N' ', N''), ISNULL(j.W1, N''))), N''),
           j.ItemCode, j.ItemName, j.BrandId, j.BrandName, j.Model, j.ItemFamilyId, j.FamilyName, j.Country,
           j.WarehouseId, j.WarehouseName, j.Description, j.WarrantyMonths,
           MinQuantity = ISNULL(j.MinQuantity, 0), j.MaxQuantity, j.IsBivac,
           j.BaseUnitTypeId, j.BaseUnitName, j.BaseSku, j.BaseBarcode,
           j.Unit2TypeId, j.Unit2Name, j.Unit2Formula, j.Unit2Sku, j.Unit2Barcode
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ------------------------------------------------------------------ 4. Commit (all non-error rows, one transaction) */

CREATE OR ALTER PROCEDURE inventory.usp_ItemImport_Commit
    @Rows     inventory.tvp_ItemImportRow READONLY,
    @FileName NVARCHAR(255),
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 63000, 'File name is required.', 1;

    CREATE TABLE #v
    (
        RowNumber INT PRIMARY KEY, Status NVARCHAR(10), Message NVARCHAR(2000),
        ItemCode NVARCHAR(50), ItemName NVARCHAR(200), BrandId INT, BrandName NVARCHAR(150), Model NVARCHAR(100),
        ItemFamilyId INT, FamilyName NVARCHAR(150), Country NVARCHAR(10), WarehouseId INT, WarehouseName NVARCHAR(150),
        Description NVARCHAR(1000), WarrantyMonths INT, MinQuantity INT, MaxQuantity INT, IsBivac BIT,
        BaseUnitTypeId INT, BaseUnitName NVARCHAR(50), BaseSku NVARCHAR(50), BaseBarcode NVARCHAR(50),
        Unit2TypeId INT, Unit2Name NVARCHAR(50), Unit2Formula INT, Unit2Sku NVARCHAR(50), Unit2Barcode NVARCHAR(50)
    );
    CREATE TABLE #ids (RowNumber INT PRIMARY KEY, ItemId INT NOT NULL);

    INSERT INTO #v (RowNumber, Status, Message, ItemCode, ItemName, BrandId, BrandName, Model, ItemFamilyId, FamilyName, Country,
                    WarehouseId, WarehouseName, Description, WarrantyMonths, MinQuantity, MaxQuantity, IsBivac,
                    BaseUnitTypeId, BaseUnitName, BaseSku, BaseBarcode, Unit2TypeId, Unit2Name, Unit2Formula, Unit2Sku, Unit2Barcode)
    EXEC inventory.usp_ItemImport_Validate @Rows;

    DECLARE @Total    INT = (SELECT COUNT(*) FROM #v),
            @Errors   INT = (SELECT COUNT(*) FROM #v WHERE Status = N'Error'),
            @Warnings INT = (SELECT COUNT(*) FROM #v WHERE Status = N'Warning');
    IF @Total = 0 THROW 63000, 'The file contains no rows to import.', 1;
    IF @Total = @Errors THROW 63001, 'Every row contains an error - nothing was imported. Download the error report, fix the file and try again.', 1;

    DECLARE @LogId INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Items (MERGE + OUTPUT captures the new identity per source row).
        MERGE inventory.Items AS t
        USING (SELECT * FROM #v WHERE Status <> N'Error') AS s ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (ItemCode, ItemName, BrandId, Model, ItemFamilyId, CountryOfOrigin, DefaultWarehouseId, Description,
                    WarrantyMonths, MinQuantity, MaxQuantity, IsBivac, IsActive, CreatedBy)
            VALUES (s.ItemCode, s.ItemName, s.BrandId, s.Model, s.ItemFamilyId, s.Country, s.WarehouseId, s.Description,
                    s.WarrantyMonths, s.MinQuantity, s.MaxQuantity, s.IsBivac, 1, @UserId)
        OUTPUT s.RowNumber, inserted.Id INTO #ids (RowNumber, ItemId);

        -- Base units: formula 1, Sales unit; also Purchase unit when the row has no Unit 2.
        INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode, IsSalesUnit, IsPurchaseUnit, IsBaseUnit, CreatedBy)
        SELECT i.ItemId, v.BaseUnitTypeId, 1, v.BaseSku, v.BaseBarcode, 1, CASE WHEN v.Unit2TypeId IS NULL THEN 1 ELSE 0 END, 1, @UserId
        FROM #v v JOIN #ids i ON i.RowNumber = v.RowNumber;

        -- Unit 2: Purchase unit.
        INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode, IsSalesUnit, IsPurchaseUnit, IsBaseUnit, CreatedBy)
        SELECT i.ItemId, v.Unit2TypeId, v.Unit2Formula, v.Unit2Sku, v.Unit2Barcode, 0, 1, 0, @UserId
        FROM #v v JOIN #ids i ON i.RowNumber = v.RowNumber
        WHERE v.Unit2TypeId IS NOT NULL;

        INSERT INTO inventory.ItemImportLogs (FileName, TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
        VALUES (LTRIM(RTRIM(@FileName)), @Total, @Total - @Errors, @Warnings, @Errors, @UserId);
        SET @LogId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- Result set 1: summary.  Result set 2: created items.
    SELECT LogId = @LogId, TotalRows = @Total, ImportedRows = @Total - @Errors, WarningRows = @Warnings, RejectedRows = @Errors;

    SELECT i.ItemId AS Id, v.RowNumber, v.ItemCode, v.ItemName, v.BrandName, v.FamilyName, v.WarehouseName,
           UnitCount = CASE WHEN v.Unit2TypeId IS NULL THEN 1 ELSE 2 END
    FROM #v v JOIN #ids i ON i.RowNumber = v.RowNumber
    ORDER BY v.RowNumber;
END
GO

/* ------------------------------------------------------------------ 5. Permission */

MERGE security.Permissions AS target
USING (VALUES (N'inventory.items.import', N'Import items from Excel', N'Inventory', N'Create items in bulk from an Excel file.', 435))
      AS source (Code, Name, Module, Description, SortOrder)
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
WHERE p.Code = N'inventory.items.import'
  AND r.IsSystem = 1
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 6. Self-test (validate only - creates nothing) */

DECLARE @t inventory.tvp_ItemImportRow;
INSERT INTO @t (RowNumber, ItemCode, ItemName, BrandRef, Model, FamilyRef, Country, WarehouseRef, BivacText, BaseUnitName, BaseSku, BaseBarcode,
                Unit2Name, Unit2Formula, Unit2Sku)
VALUES (2, N'TVS-HLX150', N'TVS HLX 150',         N'TVS',     N'HLX 150', N'FAM-001',       N'IN', N'WH-001',        N'Yes', N'PC', N'HLX150-PC',  N'8901234500011', NULL,   NULL, NULL),        -- Valid
       (3, N'TVS-AP160',  N'Apache RTR 160',      N'BRD-001', NULL,       N'Motorcycles',   N'IN', N'Main Warehouse', N'No', N'PC', N'AP160-PC',   NULL,             NULL,   NULL, NULL),        -- Error: code exists
       (4, N'BAT-12V',    N'Battery 12V 5Ah',     N'Exide',   NULL,       N'FAM-001-03-01', N'IN', N'WH-001',        N'No',  N'PC', N'BAT12-PC',   NULL,             N'Box', 10,   N'BAT12-BOX'), -- Error: brand unknown
       (5, N'OIL-10W40',  N'Engine Oil 10W40 1L', N'TVS',     NULL,       N'FAM-001-01',    N'IN', N'WH-001',        N'no',  N'PC', N'OIL1040-PC', NULL,             NULL,   NULL, NULL);        -- Warning: no barcode

EXEC inventory.usp_ItemImport_Validate @Rows = @t;
GO

SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE Code = N'inventory.items.import';
PRINT 'Inventory - Item import engine is ready.';
GO
