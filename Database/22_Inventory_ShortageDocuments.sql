/* =====================================================================================
   Inventory_Shipment - 22: SHORTAGE planning documents (replaces the live-only shortage report)

   A shortage is now a saved planning document with its own history:
     Draft  - editable, can be recalculated (live figures refreshed, manual values kept), deleted
     Posted - read-only historical SNAPSHOT (nothing is recalculated when viewed); purchase orders are created
              from it and carry the Shortage No. (Shortage -> PO -> Purchase Invoice traceability)
   One document = one warehouse (quantities), one branch (for the PO), one supplier (for the PO).

   Rule (per line, base units):
     Stock + Transit          = Current Inventory + Transit Qty
     Total Expected Stock     = Current Inventory + Transit Qty + Outstanding Order Qty
     Expected Requirement     = Expected Monthly Sales x Lead Time (Month)
     Shortage Qty             = max(0, Expected Requirement - Total Expected Stock)
     Coverage (months)        = Total Expected Stock / Expected Monthly Sales
     Container Requirement    = Required Qty (purchase unit) x packing / PC per Container
   Sources:
     Current Inventory     = stock ledger on hand in the warehouse
     Outstanding Order Qty = open purchase-order lines for the warehouse: remaining - in transit
     Transit Qty           = shipped but not yet received on those lines (NEW: purchase.usp_PurchaseDocument_MarkShipped
                             sets ShippedQuantityBase until the Shipment module exists)
     Expected Monthly Sales = net Sales-family outflow of the last "Months of history" months in the warehouse / months,
                             overridable per line (ExpectedMonthlySalesManual)
     PC per Container      = inventory.Items.PcPerContainer (NEW), overridable per line
     Required Qty          = manual, in the item's PURCHASE unit; default = shortage rounded up to that unit

   Objects:
     inventory.DocumentTypes  + YearInNumber, NextNumberYear; type SHR (prefix SHR-, year in number: SHR-2026-000001)
     inventory.DocumentSequences + Year (per branch AND year sequences); usp_DocumentType_NextNumber / _List / _Update re-created
     inventory.Items          + PcPerContainer; usp_Item_Get / usp_Item_SetPurchasing re-created
     purchase.PurchaseDocumentLines + ShippedQuantityBase; purchase.PurchaseDocuments + SourceShortageId;
     purchase.tvp_ShippedLine, usp_PurchaseDocument_MarkShipped; usp_PurchaseDocument_Get re-created (transit + shortage link)
     inventory.ShortageDocuments / ShortageDocumentLines / ShortageDocumentAudit, tvp_ShortageLine
     inventory.fn_Shortage_Live (the live figures for one warehouse), usp_Shortage_Calculate (live rows for the page),
     usp_ShortageDocument_Search / _Get / _Save / _Recalculate / _Post / _Delete / _CreatePurchaseOrder
     (inventory.usp_Shortage_Report of script 21 is DROPPED - the API switches to usp_Shortage_Calculate)
   Errors 66xxx: 66000 validation, 66004 concurrency, 66005 not a draft, 66006 not found, 66009 no lines,
                 66010 invalid status, 66011 nothing to order
   Permissions (module Inventory): inventory.shortages.view 950 / create 960 / post 970 / delete 980

   Requires 19, 20, 21. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

-- sqlcmd defaults to QUOTED_IDENTIFIER OFF; the persisted computed columns of ShortageDocumentLines need it ON
-- in every procedure that writes to the table (the setting is captured when the procedure is created).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentLines', N'U') IS NULL OR OBJECT_ID(N'inventory.DocumentSequences', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 19, 20 and 21 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Numbering: year segment */

IF COL_LENGTH(N'inventory.DocumentTypes', N'YearInNumber') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        YearInNumber   BIT NOT NULL CONSTRAINT DF_DocumentTypes_YearInNumber DEFAULT (0),
        NextNumberYear INT NULL;
    PRINT 'DocumentTypes: added YearInNumber, NextNumberYear';
END
GO

IF COL_LENGTH(N'inventory.DocumentSequences', N'Year') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentSequences DROP CONSTRAINT PK_DocumentSequences;
    ALTER TABLE inventory.DocumentSequences ADD [Year] INT NOT NULL CONSTRAINT DF_DocumentSequences_Year DEFAULT (0);
    ALTER TABLE inventory.DocumentSequences ADD CONSTRAINT PK_DocumentSequences PRIMARY KEY CLUSTERED (DocumentTypeId, BranchId, [Year]);
    PRINT 'DocumentSequences: sequences are now per type + branch + year';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'SHR', N'Shortage Plan', N'Inventory', 0, N'SHR-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

UPDATE inventory.DocumentTypes SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 0, YearInNumber = 1 WHERE Code = N'SHR';
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_Update
    @Id              INT,
    @Name            NVARCHAR(100),
    @NumberPrefix    NVARCHAR(10),
    @NumberLength    TINYINT,
    @NumberOnPost    BIT,
    @RequiresReason  BIT,
    @DefaultPricing  NVARCHAR(10),
    @PriceEditable   BIT,
    @NumberPerBranch BIT,
    @IsActive        BIT,
    @RowVersion      BINARY(8) = NULL,
    @UserId          INT       = NULL,
    @YearInNumber    BIT       = NULL     -- NULL = unchanged
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @NumberPrefix = NULLIF(LTRIM(RTRIM(@NumberPrefix)), N'');
    IF @Name IS NULL THROW 62000, 'Name is required.', 1;
    IF @NumberPrefix IS NULL THROW 62000, 'Number prefix is required.', 1;
    IF @NumberLength IS NULL OR @NumberLength NOT BETWEEN 3 AND 10 THROW 62000, 'Number length must be between 3 and 10.', 1;
    IF @DefaultPricing NOT IN (N'Cost', N'PriceList', N'None') THROW 62000, 'Default pricing must be Cost, PriceList or None.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id) THROW 62006, 'Document type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 62004, 'This document type was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.DocumentTypes
    SET Name = @Name, NumberPrefix = @NumberPrefix, NumberLength = @NumberLength, NumberOnPost = ISNULL(@NumberOnPost, 0),
        RequiresReason = ISNULL(@RequiresReason, 0), DefaultPricing = @DefaultPricing, PriceEditable = ISNULL(@PriceEditable, 1),
        NumberPerBranch = ISNULL(@NumberPerBranch, 1), YearInNumber = ISNULL(@YearInNumber, YearInNumber), IsActive = ISNULL(@IsActive, 1),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Prefix [+ branch code + '-'] [+ year + '-'] + zero-padded sequence.  SHR-2026-000001 / INV-KLW-000001 / IN-000001.
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT,
    @BranchId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId INT, @Prefix NVARCHAR(10), @Len TINYINT, @PerBranch BIT, @YearIn BIT;
    SELECT @TypeId = Id, @Prefix = NumberPrefix, @Len = NumberLength, @PerBranch = NumberPerBranch, @YearIn = YearInNumber
    FROM inventory.DocumentTypes WHERE Code = @Code AND IsActive = 1;
    IF @TypeId IS NULL THROW 62008, 'Document type not found or inactive.', 1;

    DECLARE @Year INT = YEAR(SYSUTCDATETIME());
    DECLARE @SeqYear INT = CASE WHEN @YearIn = 1 THEN @Year ELSE 0 END;
    DECLARE @Taken TABLE (Number INT);
    DECLARE @Middle NVARCHAR(20) = N'';

    IF @PerBranch = 1 AND @BranchId IS NOT NULL
    BEGIN
        DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
        IF @BranchCode IS NULL THROW 62008, 'Branch not found.', 1;

        MERGE inventory.DocumentSequences WITH (HOLDLOCK) AS t
        USING (SELECT @TypeId AS DocumentTypeId, @BranchId AS BranchId, @SeqYear AS [Year]) AS s
            ON t.DocumentTypeId = s.DocumentTypeId AND t.BranchId = s.BranchId AND t.[Year] = s.[Year]
        WHEN MATCHED THEN UPDATE SET NextNumber = t.NextNumber + 1
        WHEN NOT MATCHED THEN INSERT (DocumentTypeId, BranchId, [Year], NextNumber) VALUES (s.DocumentTypeId, s.BranchId, s.[Year], 2)
        OUTPUT ISNULL(deleted.NextNumber, 1) INTO @Taken (Number);

        SET @Middle = UPPER(LEFT(@BranchCode, 8)) + N'-';
    END
    ELSE
    BEGIN
        UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
        SET NextNumber     = CASE WHEN @YearIn = 1 AND ISNULL(NextNumberYear, 0) <> @Year THEN 2 ELSE NextNumber + 1 END,
            NextNumberYear = CASE WHEN @YearIn = 1 THEN @Year ELSE NextNumberYear END
        OUTPUT CASE WHEN @YearIn = 1 AND ISNULL(deleted.NextNumberYear, 0) <> @Year THEN 1 ELSE deleted.NextNumber END INTO @Taken (Number)
        WHERE Id = @TypeId;
    END

    IF @YearIn = 1 SET @Middle = @Middle + CAST(@Year AS NVARCHAR(4)) + N'-';

    SELECT @DocumentNumber = @Prefix + @Middle + RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len) FROM @Taken;
END
GO

/* ================================================================== 2. Items: PC per container */

IF COL_LENGTH(N'inventory.Items', N'PcPerContainer') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD PcPerContainer INT NULL CONSTRAINT CK_Items_PcPerContainer CHECK (PcPerContainer IS NULL OR PcPerContainer > 0);
    PRINT 'Items: added PcPerContainer';
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT = NULL,
    @LeadTimeDays      INT = NULL,
    @UserId            INT = NULL,
    @PcPerContainer    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @PcPerContainer IS NOT NULL AND @PcPerContainer <= 0 THROW 56000, 'PC per container must be greater than zero.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, PcPerContainer = @PcPerContainer,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                               WHERE m.ItemId = i.Id AND m.DocumentFamily = N'Purchase' AND m.QuantityBase > 0 AND m.IsReversal = 0
                               ORDER BY m.MovementDate DESC, m.Id DESC),
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays, i.PcPerContainer,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 3. Purchase: transit (shipped) quantities + shortage link */

IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ShippedQuantityBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocumentLines ADD ShippedQuantityBase INT NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Shipped DEFAULT (0);
    PRINT 'PurchaseDocumentLines: added ShippedQuantityBase';
END
GO

IF TYPE_ID(N'purchase.tvp_ShippedLine') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_ShippedLine AS TABLE
    (
        LineId              INT NOT NULL PRIMARY KEY,
        ShippedQuantityBase INT NOT NULL      -- total shipped so far on that line (base units), 0..QuantityBase
    );
    PRINT 'Created type purchase.tvp_ShippedLine';
END
GO

-- Records what the supplier has shipped (in transit) on an OPEN purchase order. NULL/empty @Lines = everything shipped.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_MarkShipped
    @Id         INT,
    @Lines      purchase.tvp_ShippedLine READONLY,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' OR @Status <> 2 THROW 65010, 'Shipped quantities can only be recorded on an open (posted) purchase order.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM @Lines s LEFT JOIN purchase.PurchaseDocumentLines l ON l.Id = s.LineId AND l.DocumentId = @Id
               WHERE l.Id IS NULL OR s.ShippedQuantityBase < 0 OR s.ShippedQuantityBase > l.QuantityBase)
        THROW 65000, 'A shipped quantity is negative, above the ordered quantity, or refers to a line of another document.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF EXISTS (SELECT 1 FROM @Lines)
            UPDATE l SET ShippedQuantityBase = s.ShippedQuantityBase
            FROM purchase.PurchaseDocumentLines l INNER JOIN @Lines s ON s.LineId = l.Id;
        ELSE
            UPDATE purchase.PurchaseDocumentLines SET ShippedQuantityBase = QuantityBase WHERE DocumentId = @Id;

        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Shipped quantities recorded: ' + CAST((SELECT SUM(ShippedQuantityBase) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) AS NVARCHAR(20)) + N' base unit(s) in transit', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 4. Shortage documents */

IF OBJECT_ID(N'inventory.ShortageDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ShortageDocuments
    (
        Id                      INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId          INT            NOT NULL,     -- SHR
        DocumentNumber          NVARCHAR(30)   NOT NULL,     -- SHR-2026-000001 (assigned at creation)
        Description             NVARCHAR(200)  NOT NULL,
        DocumentDate            DATE           NOT NULL,
        BranchId                INT            NOT NULL,     -- for the purchase order
        WarehouseId             INT            NOT NULL,     -- quantities are computed here
        SupplierId              INT            NOT NULL,     -- for the purchase order
        LeadTimeMonths          DECIMAL(6,2)   NOT NULL,     -- "Lead Time (Month)"
        MonthsOfHistory         INT            NOT NULL CONSTRAINT DF_ShortageDocuments_History DEFAULT (3),   -- months used for Expected Monthly Sales
        Notes                   NVARCHAR(1000) NULL,
        Status                  TINYINT        NOT NULL CONSTRAINT DF_ShortageDocuments_Status DEFAULT (1),   -- 1 Draft, 2 Posted
        TotalLines              INT            NOT NULL CONSTRAINT DF_ShortageDocuments_Lines DEFAULT (0),
        TotalShortageBase       INT            NOT NULL CONSTRAINT DF_ShortageDocuments_Shortage DEFAULT (0),
        TotalRequiredBase       INT            NOT NULL CONSTRAINT DF_ShortageDocuments_Required DEFAULT (0),
        TotalContainers         DECIMAL(9,2)   NOT NULL CONSTRAINT DF_ShortageDocuments_Containers DEFAULT (0),   -- sum of container requirements
        ContainersRounded       INT            NOT NULL CONSTRAINT DF_ShortageDocuments_ContainersRounded DEFAULT (0),
        ContainerUtilizationPct DECIMAL(5,2)   NULL,
        CalculatedAtUtc         DATETIME2(3)   NULL,         -- last time the live figures were taken
        PostedAtUtc             DATETIME2(3)   NULL,
        PostedBy                INT            NULL,
        CreatedAtUtc            DATETIME2(3)   NOT NULL CONSTRAINT DF_ShortageDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy               INT            NULL,
        UpdatedAtUtc            DATETIME2(3)   NULL,
        UpdatedBy               INT            NULL,
        RowVersion              ROWVERSION     NOT NULL,
        CONSTRAINT PK_ShortageDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ShortageDocuments_Number UNIQUE (DocumentNumber),
        CONSTRAINT CK_ShortageDocuments_Status CHECK (Status IN (1, 2)),
        CONSTRAINT CK_ShortageDocuments_LeadTime CHECK (LeadTimeMonths > 0),
        CONSTRAINT CK_ShortageDocuments_History CHECK (MonthsOfHistory BETWEEN 1 AND 36),
        CONSTRAINT FK_ShortageDocuments_Type      FOREIGN KEY (DocumentTypeId) REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_ShortageDocuments_Branch    FOREIGN KEY (BranchId)       REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_ShortageDocuments_Warehouse FOREIGN KEY (WarehouseId)    REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_ShortageDocuments_Supplier  FOREIGN KEY (SupplierId)     REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_ShortageDocuments_PostedBy  FOREIGN KEY (PostedBy)       REFERENCES security.Users (Id),
        CONSTRAINT FK_ShortageDocuments_CreatedBy FOREIGN KEY (CreatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_ShortageDocuments_UpdatedBy FOREIGN KEY (UpdatedBy)      REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ShortageDocuments_Date      ON inventory.ShortageDocuments (DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_ShortageDocuments_Warehouse ON inventory.ShortageDocuments (WarehouseId, Status);
    CREATE NONCLUSTERED INDEX IX_ShortageDocuments_Supplier  ON inventory.ShortageDocuments (SupplierId);
    PRINT 'Created inventory.ShortageDocuments';
END
GO

IF OBJECT_ID(N'inventory.ShortageDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ShortageDocumentLines
    (
        Id                        INT IDENTITY(1,1) NOT NULL,
        DocumentId                INT           NOT NULL,
        LineNumber                INT           NOT NULL,
        ItemId                    INT           NOT NULL,
        -- snapshot of the live figures (base units)
        CurrentInventoryBase      INT           NOT NULL,
        TransitBase               INT           NOT NULL,
        OutstandingOrderBase      INT           NOT NULL,
        ExpectedMonthlySalesBase  DECIMAL(18,2) NOT NULL,      -- computed from history
        ExpectedMonthlySalesManual DECIMAL(18,2) NULL,         -- user override
        LeadTimeMonths            DECIMAL(6,2)  NOT NULL,      -- copied from the header (needed by the computed columns)
        -- derived (never recalculated on read)
        StockPlusTransitBase      AS (CurrentInventoryBase + TransitBase) PERSISTED,
        TotalExpectedStockBase    AS (CurrentInventoryBase + TransitBase + OutstandingOrderBase) PERSISTED,
        EffectiveMonthlySales     AS (ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase)) PERSISTED,
        ExpectedRequirementBase   AS (CONVERT(DECIMAL(18,2), ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths)) PERSISTED,
        ShortageBase              AS (CASE WHEN ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths - (CurrentInventoryBase + TransitBase + OutstandingOrderBase) > 0
                                           THEN CONVERT(INT, CEILING(ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths - (CurrentInventoryBase + TransitBase + OutstandingOrderBase)))
                                           ELSE 0 END) PERSISTED,
        CoverageMonths            AS (CASE WHEN ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) > 0
                                           THEN CONVERT(DECIMAL(9,2), (CurrentInventoryBase + TransitBase + OutstandingOrderBase) / ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase)) END) PERSISTED,
        -- ordering
        PurchaseItemUnitId        INT           NOT NULL,
        PurchasePackingFormula    INT           NOT NULL,
        RequiredQty               INT           NOT NULL CONSTRAINT DF_ShortageDocumentLines_Required DEFAULT (0),   -- purchase unit, manual
        RequiredBase              AS (RequiredQty * PurchasePackingFormula) PERSISTED,
        PcPerContainer            INT           NULL,
        ContainerRequirement      AS (CASE WHEN PcPerContainer > 0 THEN CONVERT(DECIMAL(9,2), RequiredQty * PurchasePackingFormula * 1.0 / PcPerContainer) END) PERSISTED,
        -- info snapshot
        MinQuantity               INT           NULL,
        MaxQuantity               INT           NULL,
        LastCost                  DECIMAL(18,6) NULL,
        Notes                     NVARCHAR(300) NULL,
        CONSTRAINT PK_ShortageDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ShortageDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT UQ_ShortageDocumentLines_Item UNIQUE (DocumentId, ItemId),
        CONSTRAINT CK_ShortageDocumentLines_Required CHECK (RequiredQty >= 0),
        CONSTRAINT CK_ShortageDocumentLines_Container CHECK (PcPerContainer IS NULL OR PcPerContainer > 0),
        CONSTRAINT CK_ShortageDocumentLines_Sales CHECK (ExpectedMonthlySalesManual IS NULL OR ExpectedMonthlySalesManual >= 0),
        CONSTRAINT FK_ShortageDocumentLines_Document FOREIGN KEY (DocumentId)         REFERENCES inventory.ShortageDocuments (Id),
        CONSTRAINT FK_ShortageDocumentLines_Item     FOREIGN KEY (ItemId)             REFERENCES inventory.Items (Id),
        CONSTRAINT FK_ShortageDocumentLines_Unit     FOREIGN KEY (PurchaseItemUnitId) REFERENCES inventory.ItemUnits (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ShortageDocumentLines_Document ON inventory.ShortageDocumentLines (DocumentId);
    PRINT 'Created inventory.ShortageDocumentLines';
END
GO

IF OBJECT_ID(N'inventory.ShortageDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ShortageDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Recalculated | Posted | POCreated
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_ShortageDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ShortageDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ShortageDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ShortageDocumentAudit_Document ON inventory.ShortageDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created inventory.ShortageDocumentAudit';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'SourceShortageId') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD SourceShortageId INT NULL
        CONSTRAINT FK_PurchaseDocuments_Shortage FOREIGN KEY REFERENCES inventory.ShortageDocuments (Id);
    PRINT 'PurchaseDocuments: added SourceShortageId';
END
GO

IF TYPE_ID(N'inventory.tvp_ShortageLine') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ShortageLine AS TABLE
    (
        LineNumber                 INT           NOT NULL PRIMARY KEY,
        ItemId                     INT           NOT NULL,
        RequiredQty                INT           NULL,        -- purchase unit; NULL = suggested (shortage rounded up)
        ExpectedMonthlySalesManual DECIMAL(18,2) NULL,        -- NULL = computed value
        PcPerContainer             INT           NULL,        -- NULL = the item's value
        Notes                      NVARCHAR(300) NULL
    );
    PRINT 'Created type inventory.tvp_ShortageLine';
END
GO

/* ------------------------------------------------------------------ 4a. Live figures (one warehouse) */

IF OBJECT_ID(N'inventory.usp_Shortage_Report', N'P') IS NOT NULL DROP PROCEDURE inventory.usp_Shortage_Report;
GO

CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = i.PcPerContainer,
           CurrentInventoryBase     = inventory.fn_StockOnHand(i.Id, @WarehouseId),
           TransitBase              = ISNULL(po.Transit, 0),
           OutstandingOrderBase     = ISNULL(po.Outstanding, 0),
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), CAST(ISNULL(s.Sold, 0) AS DECIMAL(18,4)) / NULLIF(@MonthsOfHistory, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        SELECT Transit     = SUM(CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END),
               Outstanding = SUM((l.QuantityBase - l.ReceivedQuantityBase)
                                 - CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE dt.Code = N'PO' AND d.Status = 2 AND l.ItemId = i.Id AND l.WarehouseId = @WarehouseId AND l.QuantityBase > l.ReceivedQuantityBase
    ) po
    OUTER APPLY
    (
        SELECT Sold = SUM(-m.QuantityBase)
        FROM inventory.StockMovements m
        WHERE m.ItemId = i.Id AND m.WarehouseId = @WarehouseId AND m.DocumentFamily = N'Sales'
          AND m.MovementDate >= DATEADD(MONTH, -@MonthsOfHistory, CAST(SYSUTCDATETIME() AS DATE))
    ) s
    OUTER APPLY
    (
        SELECT TOP (1) u.Id AS ItemUnitId, u.PackingFormula, t.UnitTypeName
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC
    ) pu
    WHERE i.IsActive = 1
);
GO

-- Live rows for the page ("Load items" on a new/draft document). Supplier filter = default supplier, else last supplier.
CREATE OR ALTER PROCEDURE inventory.usp_Shortage_Calculate
    @WarehouseId     INT,
    @SupplierId      INT           = NULL,
    @LeadTimeMonths  DECIMAL(6,2)  = 6,
    @MonthsOfHistory INT           = 3,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Search          NVARCHAR(200) = NULL,
    @OnlyShortages   BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 SET @LeadTimeMonths = 6;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory < 1 SET @MonthsOfHistory = 3;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;

    SELECT x.ItemId, x.ItemCode, x.ItemName, b.BrandName, f.FamilyName, x.IsBivac,
           x.CurrentInventoryBase, x.TransitBase, x.OutstandingOrderBase,
           StockPlusTransitBase   = x.CurrentInventoryBase + x.TransitBase,
           TotalExpectedStockBase = x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, x.SoldInPeriodBase, MonthsOfHistory = @MonthsOfHistory, LeadTimeMonths = @LeadTimeMonths,
           ExpectedRequirementBase = CONVERT(DECIMAL(18,2), x.ExpectedMonthlySalesBase * @LeadTimeMonths),
           ShortageBase = c.ShortageBase,
           CoverageMonths = CASE WHEN x.ExpectedMonthlySalesBase > 0
                                 THEN CONVERT(DECIMAL(9,2), (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) / x.ExpectedMonthlySalesBase) END,
           x.PurchaseItemUnitId, x.PurchaseUnitName, x.PurchasePackingFormula,
           SuggestedRequiredQty = CASE WHEN c.ShortageBase > 0 THEN CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END,
           PcPerContainer = x.ItemPcPerContainer,
           ContainerRequirement = CASE WHEN x.ItemPcPerContainer > 0 AND c.ShortageBase > 0
                                       THEN CONVERT(DECIMAL(9,2), CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) * x.PurchasePackingFormula * 1.0 / x.ItemPcPerContainer) END,
           x.MinQuantity, x.MaxQuantity, x.LastCost, x.AverageCost, x.LeadTimeDays,
           SupplierId = COALESCE(x.DefaultSupplierId, x.LastSupplierId), SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN x.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END
    FROM inventory.fn_Shortage_Live(@WarehouseId, @MonthsOfHistory) x
    CROSS APPLY (SELECT ShortageBase = CASE WHEN x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase))) ELSE 0 END) c
    INNER JOIN masterdata.Brands b ON b.Id = x.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = x.ItemFamilyId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = x.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = x.LastSupplierId
    WHERE x.PurchaseItemUnitId IS NOT NULL
      AND (@SupplierId IS NULL OR COALESCE(x.DefaultSupplierId, x.LastSupplierId) = @SupplierId)
      AND (@ItemFamilyId IS NULL OR x.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR x.BrandId = @BrandId)
      AND (@Search IS NULL OR x.ItemCode LIKE N'%' + @Search + N'%' OR x.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR c.ShortageBase > 0)
    ORDER BY CASE WHEN c.ShortageBase > 0 THEN 0 ELSE 1 END, c.ShortageBase DESC, x.ItemCode;
END
GO

/* ------------------------------------------------------------------ 4b. Search / Get */

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Search
    @Search        NVARCHAR(100) = NULL,    -- number or description
    @WarehouseId   INT          = NULL,
    @BranchId      INT          = NULL,
    @SupplierId    INT          = NULL,
    @Status        TINYINT      = NULL,     -- 1 Draft | 2 Posted
    @CreatedBy     INT          = NULL,
    @DateFrom      DATE         = NULL,
    @DateTo        DATE         = NULL,
    @SortColumn    NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | Description | WarehouseName | SupplierName | Status | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'DESC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'Description', N'WarehouseName', N'SupplierName', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, d.LeadTimeMonths, d.MonthsOfHistory, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded,
           PurchaseOrders = (SELECT COUNT(*) FROM purchase.PurchaseDocuments p WHERE p.SourceShortageId = d.Id AND p.Status <> 3),
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.Description LIKE N'%' + @Search + N'%')
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@CreatedBy IS NULL OR d.CreatedBy = @CreatedBy)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'Description' THEN d.Description
                             WHEN N'WarehouseName' THEN w.WarehouseName WHEN N'SupplierName' THEN sp.PartyName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'Description' THEN d.Description
                             WHEN N'WarehouseName' THEN w.WarehouseName WHEN N'SupplierName' THEN sp.PartyName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: header, lines (the snapshot), purchase orders created from it, audit.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.LeadTimeMonths, d.MonthsOfHistory, d.Notes, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded, d.ContainerUtilizationPct,
           d.CalculatedAtUtc, d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName, d.RowVersion
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, br.BrandName, f.FamilyName, i.IsBivac,
           l.CurrentInventoryBase, l.TransitBase, l.OutstandingOrderBase, l.StockPlusTransitBase, l.TotalExpectedStockBase,
           l.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, l.EffectiveMonthlySales, l.LeadTimeMonths,
           l.ExpectedRequirementBase, l.ShortageBase, l.CoverageMonths,
           l.PurchaseItemUnitId, ut.UnitTypeName AS PurchaseUnitName, l.PurchasePackingFormula,
           l.RequiredQty, l.RequiredBase, l.PcPerContainer, l.ContainerRequirement,
           l.MinQuantity, l.MaxQuantity, l.LastCost, l.Notes
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.PurchaseItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT p.Id, p.DocumentNumber, p.DocumentDate, p.Status, p.TotalAmount, c.CurrencyCode, p.CreatedAtUtc
    FROM purchase.PurchaseDocuments p
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    WHERE p.SourceShortageId = @Id
    ORDER BY p.CreatedAtUtc;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.ShortageDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ------------------------------------------------------------------ 4c. Save (draft) / Recalculate */

-- Shared: replace the lines of a draft with fresh live figures for the given items (manual values from the TVP).
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_WriteLines
    @Id     INT,
    @Lines  inventory.tvp_ShortageLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @WarehouseId INT, @Months INT, @LeadTime DECIMAL(6,2);
    SELECT @WarehouseId = WarehouseId, @Months = MonthsOfHistory, @LeadTime = LeadTimeMonths FROM inventory.ShortageDocuments WHERE Id = @Id;

    DECLARE @Msg NVARCHAR(300);
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
                          CASE WHEN i.Id IS NULL THEN N'item not found.' WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
                               WHEN l.RequiredQty < 0 THEN N'required quantity cannot be negative.'
                               WHEN l.ExpectedMonthlySalesManual < 0 THEN N'expected monthly sales cannot be negative.'
                               WHEN l.PcPerContainer <= 0 THEN N'PC per container must be greater than zero.' END
    FROM @Lines l LEFT JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR l.RequiredQty < 0 OR l.ExpectedMonthlySalesManual < 0 OR l.PcPerContainer <= 0
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 66000, @Msg, 1;
    IF EXISTS (SELECT ItemId FROM @Lines GROUP BY ItemId HAVING COUNT(*) > 1) THROW 66000, 'An item appears more than once.', 1;

    DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    INSERT INTO inventory.ShortageDocumentLines (DocumentId, LineNumber, ItemId, CurrentInventoryBase, TransitBase, OutstandingOrderBase,
                                                 ExpectedMonthlySalesBase, ExpectedMonthlySalesManual, LeadTimeMonths,
                                                 PurchaseItemUnitId, PurchasePackingFormula, RequiredQty, PcPerContainer,
                                                 MinQuantity, MaxQuantity, LastCost, Notes)
    SELECT @Id, l.LineNumber, l.ItemId, x.CurrentInventoryBase, x.TransitBase, x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, @LeadTime,
           x.PurchaseItemUnitId, x.PurchasePackingFormula,
           RequiredQty = ISNULL(l.RequiredQty,
                                CASE WHEN s.ShortageBase > 0 THEN CEILING(CAST(s.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END),
           ISNULL(l.PcPerContainer, x.ItemPcPerContainer),
           x.MinQuantity, x.MaxQuantity, x.LastCost, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.fn_Shortage_Live(@WarehouseId, @Months) x ON x.ItemId = l.ItemId
    CROSS APPLY (SELECT ShortageBase = CASE WHEN ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * @LeadTime - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * @LeadTime - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase)))
                                            ELSE 0 END) s
    WHERE x.PurchaseItemUnitId IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @Lines l WHERE NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines s WHERE s.DocumentId = @Id AND s.ItemId = l.ItemId))
        THROW 66000, 'An item has no units configured and cannot be planned.', 1;

    UPDATE d
    SET TotalLines = x.Lines, TotalShortageBase = x.Shortage, TotalRequiredBase = x.Required,
        TotalContainers = x.Containers, ContainersRounded = CEILING(x.Containers),
        ContainerUtilizationPct = CASE WHEN x.Containers > 0 THEN CONVERT(DECIMAL(5,2), 100.0 * x.Containers / CEILING(x.Containers)) END,
        CalculatedAtUtc = SYSUTCDATETIME()
    FROM inventory.ShortageDocuments d
    CROSS APPLY (SELECT COUNT(*) AS Lines, ISNULL(SUM(ShortageBase), 0) AS Shortage, ISNULL(SUM(RequiredBase), 0) AS Required,
                        ISNULL(SUM(ContainerRequirement), 0) AS Containers
                 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id) x
    WHERE d.Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Save
    @Id              INT            = NULL,   -- NULL = create (number assigned now)
    @Description     NVARCHAR(200),
    @DocumentDate    DATE,
    @BranchId        INT,
    @WarehouseId     INT,
    @SupplierId      INT,
    @LeadTimeMonths  DECIMAL(6,2),
    @MonthsOfHistory INT            = 3,
    @Notes           NVARCHAR(1000) = NULL,
    @Lines           inventory.tvp_ShortageLine READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @Description IS NULL THROW 66000, 'Description is required.', 1;
    IF @DocumentDate IS NULL THROW 66000, 'Date is required.', 1;
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 THROW 66000, 'Lead Time (Month) must be greater than zero.', 1;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory NOT BETWEEN 1 AND 36 THROW 66000, 'Months of history must be between 1 and 36.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1) THROW 66000, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1) THROW 66000, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
        IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SHR');
            EXEC inventory.usp_DocumentType_NextNumber N'SHR', @Number OUTPUT, @BranchId;

            INSERT INTO inventory.ShortageDocuments (DocumentTypeId, DocumentNumber, Description, DocumentDate, BranchId, WarehouseId, SupplierId,
                                                     LeadTimeMonths, MonthsOfHistory, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @Description, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @LeadTimeMonths, @MonthsOfHistory, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Number, @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.ShortageDocuments
            SET Description = @Description, DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, SupplierId = @SupplierId,
                LeadTimeMonths = @LeadTimeMonths, MonthsOfHistory = @MonthsOfHistory, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Draft only: refresh the live figures of the existing lines; Required Qty, manual sales and PC per container are kept.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Recalculate
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be recalculated.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;

    DECLARE @Lines inventory.tvp_ShortageLine;
    INSERT INTO @Lines (LineNumber, ItemId, RequiredQty, ExpectedMonthlySalesManual, PcPerContainer, Notes)
    SELECT LineNumber, ItemId, RequiredQty, ExpectedMonthlySalesManual, PcPerContainer, Notes
    FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines;
        UPDATE inventory.ShortageDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Recalculated', N'Live figures refreshed', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4d. Post / Delete / Create PO */

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66010, 'Only draft shortage documents can be posted.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id)
        THROW 66009, 'The shortage document has no lines. Load items before posting.', 1;

    UPDATE inventory.ShortageDocuments
    SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Posted', N'Snapshot locked', @UserId);
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be deleted.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PurchaseDocuments SET SourceShortageId = NULL WHERE SourceShortageId = @Id;
        DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;
        DELETE FROM inventory.ShortageDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM inventory.ShortageDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Posted only: one draft purchase order (header supplier / branch / warehouse) from the lines with Required Qty > 0.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_CreatePurchaseOrder
    @Id           INT,
    @DocumentDate DATE = NULL,
    @ExpectedDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @Number NVARCHAR(30), @Description NVARCHAR(200);
    SELECT @Status = Status, @BranchId = BranchId, @WarehouseId = WarehouseId, @SupplierId = SupplierId, @Number = DocumentNumber, @Description = Description
    FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 2 THROW 66010, 'Post the shortage document before creating a purchase order from it.', 1;

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, l.PurchaseItemUnitId, @WarehouseId, NULL, l.RequiredQty, NULL, NULL, NULL,
           LEFT(N'Shortage ' + @Number + ISNULL(N' - ' + l.Notes, N''), 300), NULL
    FROM inventory.ShortageDocumentLines l
    WHERE l.DocumentId = @Id AND l.RequiredQty > 0;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 66011, 'No line has a required quantity greater than zero.', 1;

    DECLARE @Notes NVARCHAR(1000) = N'Created from shortage plan ' + @Number + N' - ' + @Description;
    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = N'PO', @DocumentDate = @DocumentDate, @ExpectedDate = @ExpectedDate,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = NULL,
         @RateType = 1, @ExchangeRate = NULL, @SupplierReference = NULL, @Notes = @Notes,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

    UPDATE purchase.PurchaseDocuments SET SourceShortageId = @Id WHERE Id = @NewId;
    INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@Id, N'POCreated', N'Purchase order draft created (' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s))', @UserId);
END
GO

/* ================================================================== 5. purchase.usp_PurchaseDocument_Get re-created (transit + shortage link) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           TransitBase = CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;
END
GO

/* ================================================================== 6. Permissions + report */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'inventory.shortages.view',   N'View Shortage Plans',   N'Inventory', N'See shortage planning documents.',                         950),
        (N'inventory.shortages.create', N'Create Shortage Plans', N'Inventory', N'Create, edit and recalculate draft shortage plans.',       960),
        (N'inventory.shortages.post',   N'Post Shortage Plans',   N'Inventory', N'Post shortage plans (locks the snapshot).',                970),
        (N'inventory.shortages.delete', N'Delete Shortage Plans', N'Inventory', N'Delete draft shortage plans.',                             980)
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
WHERE p.Code LIKE N'inventory.shortages.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'inventory.shortages.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ Self-test (live calculation only) */

DECLARE @WhId INT = (SELECT TOP (1) Id FROM masterdata.Warehouses WHERE IsActive = 1 ORDER BY IsMainWarehouse DESC, Id);
IF @WhId IS NOT NULL
    EXEC inventory.usp_Shortage_Calculate @WarehouseId = @WhId, @LeadTimeMonths = 6, @MonthsOfHistory = 3, @OnlyShortages = 0;
GO

SELECT Code, Name, NumberPrefix, NumberPerBranch, YearInNumber, NextNumber, NextNumberYear FROM inventory.DocumentTypes WHERE Code = N'SHR';
PRINT 'Shortage planning documents are ready (SHR-YYYY-000001).';
GO
