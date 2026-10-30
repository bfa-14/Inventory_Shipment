SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 98: INVENTORY - LEAD TIME PER ITEM, IN MONTHS, AND FROM ITS PURCHASE HISTORY ON SHORTAGES

     1. ITEM DEFINITION KEEPS THE LEAD TIME IN MONTHS (inventory.Items.LeadTimeMonths, one decimal, 0 to 60). The days
        typed before are converted ONCE per database (inventory.OneTimeSteps, step 98.LeadTimeMonths): days / 30, rounded
        to the half month (45 days -> 1.5). LeadTimeDays stays, kept equal to months x 30 for the readers that use it.
     2. THE LEAD TIME OF AN ITEM'S HISTORY (inventory.fn_Item_LeadTimeHistory): over the goods receipts posted in the
        last 12 months whose lines come from a purchase order, the time from the order's approval (its posting) to the
        receipt's posting, weighted by the pieces received, in months of 30 days, one decimal (at least 0.1).
     3. THE LEAD TIME A SHORTAGE USES, PER ITEM (inventory.fn_Item_LeadTime), the first that has one: the history (2),
        the item's own (1), else the plan's header. Source History / Item / Plan says which; a line's lead time typed on a
        draft plan wins (Manual) and is kept by Recalculate.
     4. THE LIVE VIEW AND THE PLAN LINES COMPUTE EACH LINE WITH ITS OWN LEAD TIME: Expected requirement and Shortage
        = monthly sales x the line's lead time.

   New: inventory.Items.LeadTimeMonths; inventory.ShortageDocumentLines.LeadTimeManual / LeadTimeSource; type
        inventory.tvp_ShortageLeadTime; inventory.fn_Item_LeadTimeHistory, fn_Item_LeadTime, usp_Item_SetLeadTime.
   Re-created: inventory.usp_Item_Get (from 93), usp_Shortage_Calculate, usp_ShortageDocument_WriteLines and _Get
        (from 90), usp_ShortageDocument_Save and _Recalculate (from 25: + the line lead times).
   Errors: no new number (56000, 56006, 66000).
   Requires scripts 25, 89 and 90. Idempotent, additive: re-applied at every API start-up, and builds an empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.OneTimeSteps', N'U') IS NULL OR COL_LENGTH(N'inventory.ShortageDocumentLines', N'TransfersInBase') IS NULL
    THROW 66000, 'Script 98 requires scripts 89 and 90: apply them first.', 1;
GO

/* ================================================================== 1. Columns and type */

IF COL_LENGTH(N'inventory.Items', N'LeadTimeMonths') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD LeadTimeMonths DECIMAL(5,1) NULL
        CONSTRAINT CK_Items_LeadTimeMonths CHECK (LeadTimeMonths IS NULL OR (LeadTimeMonths >= 0 AND LeadTimeMonths <= 60));
    PRINT 'Items: added LeadTimeMonths';
END
GO

IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'LeadTimeManual') IS NULL
BEGIN
    ALTER TABLE inventory.ShortageDocumentLines ADD
        LeadTimeManual DECIMAL(6,2) NULL,      -- (98) typed on the line; NULL = worked out
        LeadTimeSource NVARCHAR(10) NULL;      -- (98) Manual | History | Item | Plan (NULL: a line saved before script 98)
    PRINT 'ShortageDocumentLines: added LeadTimeManual, LeadTimeSource';
END
GO

IF TYPE_ID(N'inventory.tvp_ShortageLeadTime') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ShortageLeadTime AS TABLE
    (
        ItemId         INT          NOT NULL PRIMARY KEY,
        LeadTimeMonths DECIMAL(6,2) NOT NULL
    );
    PRINT 'Created type inventory.tvp_ShortageLeadTime';
END
GO

/* ================================================================== 2. The days typed before, converted once */

IF NOT EXISTS (SELECT 1 FROM inventory.OneTimeSteps WHERE StepCode = N'98.LeadTimeMonths')
BEGIN
    BEGIN TRANSACTION;
    UPDATE inventory.Items
    SET LeadTimeMonths = CASE WHEN LeadTimeDays / 30.0 > 60 THEN 60
                              ELSE CAST(ROUND(LeadTimeDays / 30.0 * 2, 0) / 2 AS DECIMAL(5,1)) END
    WHERE LeadTimeDays IS NOT NULL AND LeadTimeMonths IS NULL;
    DECLARE @Converted INT = @@ROWCOUNT;
    INSERT INTO inventory.OneTimeSteps (StepCode, DoneAtUtc, Progress, Details)
    VALUES (N'98.LeadTimeMonths', SYSUTCDATETIME(), @Converted, N'Item lead times converted once from days to months (/ 30, to the half month).');
    COMMIT TRANSACTION;
    PRINT 'Lead times converted once to months: ' + CAST(@Converted AS NVARCHAR(10)) + ' item(s).';
END
GO

/* ================================================================== 3. The lead time of the history, and the one a shortage uses */

-- (98) One row per item (all items when @ItemId is NULL) that had goods received from a purchase order in the last 12
-- months: the time from the order's approval (PostedAtUtc) to the receipt's posting, weighted by the pieces received.
CREATE OR ALTER FUNCTION inventory.fn_Item_LeadTimeHistory (@ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT l.ItemId,
       Months = CAST(CASE WHEN SUM(CAST(DATEDIFF(DAY, po.PostedAtUtc, g.PostedAtUtc) AS DECIMAL(18,2)) * l.QuantityBase) / SUM(l.QuantityBase) / 30.0 < 0.1 THEN 0.1
                          ELSE ROUND(SUM(CAST(DATEDIFF(DAY, po.PostedAtUtc, g.PostedAtUtc) AS DECIMAL(18,2)) * l.QuantityBase) / SUM(l.QuantityBase) / 30.0, 1) END
                     AS DECIMAL(5,1)),
       Receipts = COUNT(DISTINCT g.Id)
FROM purchase.GoodsReceiptLines l
INNER JOIN purchase.GoodsReceipts g          ON g.Id = l.GoodsReceiptId AND g.Status = 2
                                            AND g.PostedAtUtc >= DATEADD(MONTH, -12, SYSUTCDATETIME())
INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PoLineId
INNER JOIN purchase.PurchaseDocuments po     ON po.Id = pl.DocumentId AND po.PostedAtUtc IS NOT NULL AND po.PostedAtUtc <= g.PostedAtUtc
WHERE l.QuantityBase > 0
  AND (@ItemId IS NULL OR l.ItemId = @ItemId)
GROUP BY l.ItemId;
GO

-- (98) The lead time a shortage uses for an item, the first that has one: its history, its own, else @PlanMonths.
CREATE OR ALTER FUNCTION inventory.fn_Item_LeadTime (@ItemId INT, @PlanMonths DECIMAL(6,2))
RETURNS TABLE
AS
RETURN
SELECT LeadTimeMonths = CAST(COALESCE(h.Months, NULLIF(i.LeadTimeMonths, 0), @PlanMonths) AS DECIMAL(6,2)),
       Source = CAST(CASE WHEN h.Months IS NOT NULL THEN N'History' WHEN NULLIF(i.LeadTimeMonths, 0) IS NOT NULL THEN N'Item' ELSE N'Plan' END AS NVARCHAR(10)),
       HistoryMonths = h.Months, Receipts = h.Receipts
FROM inventory.Items i
OUTER APPLY inventory.fn_Item_LeadTimeHistory(i.Id) h
WHERE i.Id = @ItemId;
GO

/* ================================================================== 4. The item's lead time in months */

-- (98) Written the way usp_Item_SetTracking writes its fields: the API calls it after the item is created or updated.
-- LeadTimeDays follows (months x 30) for the readers of the days. Nothing written when nothing differs.
CREATE OR ALTER PROCEDURE inventory.usp_Item_SetLeadTime
    @Id             INT,
    @LeadTimeMonths DECIMAL(5,1) = NULL,
    @UserId         INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56006, 'Item not found.', 1;
    IF @LeadTimeMonths IS NOT NULL AND (@LeadTimeMonths < 0 OR @LeadTimeMonths > 60)
        THROW 56000, 'Lead time must be between 0 and 60 months.', 1;
    UPDATE inventory.Items
    SET LeadTimeMonths = @LeadTimeMonths,
        LeadTimeDays = CASE WHEN @LeadTimeMonths IS NULL THEN NULL ELSE CAST(ROUND(@LeadTimeMonths * 30, 0) AS INT) END,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id
      AND (ISNULL(LeadTimeMonths, -1) <> ISNULL(@LeadTimeMonths, -1)
           OR ISNULL(LeadTimeDays, -1) <> ISNULL(CAST(ROUND(@LeadTimeMonths * 30, 0) AS INT), -1));
END
GO

-- Re-created (98) from the body of script 93: + LeadTimeMonths and the lead time of its history. Nothing else.
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
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays,
           PcPerContainer = cnt.PackingFormula,      -- from the item's Container unit
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm, i.OilQtyPerUnit,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.Note, i.Link,                           -- (87)
           i.TrackingMode, i.RequiresExpiry, i.SerialLength,   -- (93)
           i.LeadTimeMonths, LeadTimeHistoryMonths = lh.Months, LeadTimeHistoryReceipts = lh.Receipts,   -- (98)
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
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    OUTER APPLY inventory.fn_Item_LeadTimeHistory(i.Id) lh   -- (98)
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, IsContainerUnit = ut.IsContainer,
           u.LengthCm, u.WidthCm, u.HeightCm, u.WeightKg, u.RowVersion
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

/* ================================================================== 5. Shortages: each line with its own lead time */

-- Re-created (98) from the body of script 90: each row with its item's lead time (fn_Item_LeadTime, the request's
-- @LeadTimeMonths the fallback), + LeadTimeSource, LeadTimeHistoryMonths, LeadTimeReceipts. Nothing else.
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
           x.CurrentInventoryBase, x.TransitBase, x.TransfersInBase, x.OutstandingOrderBase,      -- (90) + TransfersInBase
           StockPlusTransitBase   = x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase,
           TotalExpectedStockBase = x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, x.SoldInPeriodBase, MonthsOfHistory = @MonthsOfHistory, LeadTimeMonths = lt.LeadTimeMonths,   -- (98) the item's
           LeadTimeSource = lt.Source, LeadTimeHistoryMonths = lt.HistoryMonths, LeadTimeReceipts = lt.Receipts,                     -- (98)
           ExpectedRequirementBase = CONVERT(DECIMAL(18,2), x.ExpectedMonthlySalesBase * lt.LeadTimeMonths),
           ShortageBase = c.ShortageBase,
           CoverageMonths = CASE WHEN x.ExpectedMonthlySalesBase > 0
                                 THEN CONVERT(DECIMAL(9,2), (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase) / x.ExpectedMonthlySalesBase) END,
           x.PurchaseItemUnitId, x.PurchaseUnitName, x.PurchasePackingFormula,
           SuggestedRequiredQty = CASE WHEN c.ShortageBase > 0 THEN CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END,
           PcPerContainer = x.ItemPcPerContainer, PcPerContainerFromUnit = x.PcPerContainerFromUnit,
           ContainerRequirement = CASE WHEN x.ItemPcPerContainer > 0 AND c.ShortageBase > 0
                                       THEN CONVERT(DECIMAL(9,2), CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) * x.PurchasePackingFormula * 1.0 / x.ItemPcPerContainer) END,
           x.MinQuantity, x.MaxQuantity, x.LastCost, x.AverageCost, x.LeadTimeDays,
           SupplierId = COALESCE(x.DefaultSupplierId, x.LastSupplierId), SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN x.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END
    FROM inventory.fn_Shortage_Live(@WarehouseId, @MonthsOfHistory) x
    CROSS APPLY inventory.fn_Item_LeadTime(x.ItemId, @LeadTimeMonths) lt                                                          -- (98)
    CROSS APPLY (SELECT ShortageBase = CASE WHEN x.ExpectedMonthlySalesBase * lt.LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(x.ExpectedMonthlySalesBase * lt.LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase))) ELSE 0 END) c
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

-- Re-created (98) from the body of script 90: + @LeadTimes (optional), each line's lead time typed, else its item's
-- (history, own, the header's); stored with LeadTimeManual and LeadTimeSource. Nothing else.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_WriteLines
    @Id        INT,
    @Lines     inventory.tvp_ShortageLine READONLY,
    @LeadTimes inventory.tvp_ShortageLeadTime READONLY   -- (98) the lead times typed on lines; an item left out takes its own
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
    -- (98) A lead time typed on a line: above 0, at most 60 months.
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the lead time must be above 0 and at most 60 months.'
    FROM @LeadTimes t INNER JOIN @Lines l ON l.ItemId = t.ItemId
    WHERE t.LeadTimeMonths <= 0 OR t.LeadTimeMonths > 60
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 66000, @Msg, 1;

    DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    INSERT INTO inventory.ShortageDocumentLines (DocumentId, LineNumber, ItemId, CurrentInventoryBase, TransitBase, TransfersInBase, OutstandingOrderBase,
                                                 ExpectedMonthlySalesBase, ExpectedMonthlySalesManual, LeadTimeMonths, LeadTimeManual, LeadTimeSource,   -- (98)
                                                 PurchaseItemUnitId, PurchasePackingFormula, RequiredQty, PcPerContainer, PcPerContainerFromUnit,
                                                 MinQuantity, MaxQuantity, LastCost, Notes)
    SELECT @Id, l.LineNumber, l.ItemId, x.CurrentInventoryBase, x.TransitBase, x.TransfersInBase, x.OutstandingOrderBase,   -- (90)
           x.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, ISNULL(t.LeadTimeMonths, lt.LeadTimeMonths), t.LeadTimeMonths,   -- (98)
           CASE WHEN t.LeadTimeMonths IS NOT NULL THEN N'Manual' ELSE lt.Source END,
           x.PurchaseItemUnitId, x.PurchasePackingFormula,
           RequiredQty = ISNULL(l.RequiredQty,
                                CASE WHEN s.ShortageBase > 0 THEN CEILING(CAST(s.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END),
           COALESCE(x.ItemPcPerContainer, l.PcPerContainer),            -- the Container unit always wins; else what the user typed
           CAST(CASE WHEN x.ItemPcPerContainer IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           x.MinQuantity, x.MaxQuantity, x.LastCost, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.fn_Shortage_Live(@WarehouseId, @Months) x ON x.ItemId = l.ItemId
    LEFT  JOIN @LeadTimes t ON t.ItemId = l.ItemId                                                                 -- (98)
    CROSS APPLY inventory.fn_Item_LeadTime(l.ItemId, @LeadTime) lt                                                -- (98)
    CROSS APPLY (SELECT LT = ISNULL(t.LeadTimeMonths, lt.LeadTimeMonths)) e                                        -- (98)
    CROSS APPLY (SELECT ShortageBase = CASE WHEN ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * e.LT - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * e.LT - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase)))
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

-- Re-created (98) from the body of script 25: + @LeadTimes, passed to WriteLines. Nothing else.
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
    @LeadTimes       inventory.tvp_ShortageLeadTime READONLY,   -- (98) the lead times typed on lines
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

        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines, @LeadTimes;   -- (98)

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (98) from the body of script 25: a lead time typed on a line is kept. Nothing else.
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
    -- (98) A lead time typed on a line is kept; the others are worked out again.
    DECLARE @LeadTimes inventory.tvp_ShortageLeadTime;
    INSERT INTO @LeadTimes (ItemId, LeadTimeMonths)
    SELECT ItemId, LeadTimeManual FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id AND LeadTimeManual IS NOT NULL;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines, @LeadTimes;   -- (98)
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

-- Re-created (98) from the body of script 90: the lines + LeadTimeManual, LeadTimeSource. Nothing else.
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
           l.CurrentInventoryBase, l.TransitBase, l.TransfersInBase, l.OutstandingOrderBase, l.StockPlusTransitBase, l.TotalExpectedStockBase,   -- (90)
           l.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, l.EffectiveMonthlySales, l.LeadTimeMonths,
           l.LeadTimeManual, l.LeadTimeSource,                                                                 -- (98)
           l.ExpectedRequirementBase, l.ShortageBase, l.CoverageMonths,
           l.PurchaseItemUnitId, ut.UnitTypeName AS PurchaseUnitName, l.PurchasePackingFormula,
           l.RequiredQty, l.RequiredBase, l.PcPerContainer, l.PcPerContainerFromUnit, l.ContainerRequirement,
           l.MinQuantity, l.MaxQuantity, l.LastCost, l.Notes
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.PurchaseItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    -- (77) + InvoicingStatus (0 / 1 / 2: Saved, Partially posted, Posted on an approved order)
    SELECT p.Id, p.DocumentNumber, p.DocumentDate, p.Status, p.TotalAmount, c.CurrencyCode, p.CreatedAtUtc,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments p
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(p.Id) inv
    WHERE p.SourceShortageId = @Id
    ORDER BY p.CreatedAtUtc;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.ShortageDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 6. Check */

-- 98a: items with a lead time, their months and what their history says
SELECT TOP (50) i.ItemCode, i.LeadTimeDays, i.LeadTimeMonths, HistoryMonths = h.Months, h.Receipts
FROM inventory.Items i
LEFT JOIN inventory.fn_Item_LeadTimeHistory(NULL) h ON h.ItemId = i.Id
WHERE i.LeadTimeDays IS NOT NULL OR h.ItemId IS NOT NULL
ORDER BY i.ItemCode;
PRINT 'Script 98 applied: item lead times in months; shortages take each item''s lead time from its purchase history.';
GO
