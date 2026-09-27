/* =====================================================================================
   Inventory_Shipment - 25: shortage plans take the PIECES PER CONTAINER from the item's CONTAINER UNIT

   Rule (customer):
     - The number of pieces in a container comes from the item's units: the unit whose unit type is the
       container unit (masterdata.UnitTypes.IsContainer = 1, "Container" by default). Its PackingFormula
       (base units) is the "PC per Container" of the shortage line and CANNOT be overridden there.
     - When the item has no container unit, the line starts empty and the user types the number.
     - Recalculating a draft re-applies the rule: a container unit added to the item later replaces the typed value.
     - Posted plans keep their snapshot (nothing is recalculated).

   Objects:
     masterdata.UnitTypes + IsContainer (only one unit type; "Container" is marked, created if missing)
       usp_UnitType_Search / _Get / _Lookup re-created (+ IsContainer), usp_UnitType_SetContainer (new)
     inventory.ItemUnits: every item that had inventory.Items.PcPerContainer and no container unit receives one
       (SKU <ItemCode>-CNT, not a sales / purchase / base unit). Items.PcPerContainer is no longer read.
     inventory.usp_Item_Get re-created: header PcPerContainer now comes from the container unit
       (+ PcPerContainerFromUnit), units result set + IsContainerUnit
     inventory.fn_Shortage_Live re-created (script 24 version + container unit) and usp_Shortage_Calculate
       (+ PcPerContainerFromUnit)
     inventory.ShortageDocumentLines + PcPerContainerFromUnit (snapshot of where the number came from)
     inventory.usp_ShortageDocument_WriteLines / _Get re-created
   Errors: 57000 validation, 57006 unit type not found.

   Requires scripts 22-24. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.ShortageDocumentLines', N'U') IS NULL OR OBJECT_ID(N'logistics.ContainerLines', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 22, 23 and 24 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. The container unit type */

IF COL_LENGTH(N'masterdata.UnitTypes', N'IsContainer') IS NULL
BEGIN
    ALTER TABLE masterdata.UnitTypes ADD IsContainer BIT NOT NULL CONSTRAINT DF_UnitTypes_IsContainer DEFAULT (0);
    PRINT 'UnitTypes: added IsContainer';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_UnitTypes_Container' AND object_id = OBJECT_ID(N'masterdata.UnitTypes'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_UnitTypes_Container ON masterdata.UnitTypes (IsContainer) WHERE IsContainer = 1;
GO

IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE IsContainer = 1)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE UnitTypeName = N'Container')
        INSERT INTO masterdata.UnitTypes (UnitTypeName, IsActive) VALUES (N'Container', 1);
    UPDATE masterdata.UnitTypes SET IsContainer = 1 WHERE UnitTypeName = N'Container';
    PRINT 'Unit type "Container" marked as the container unit';
END
GO

-- Re-created: + IsContainer.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Search
    @Search        NVARCHAR(50) = NULL,
    @IsActive      BIT          = NULL,
    @SortColumn    NVARCHAR(30) = N'UnitTypeName',  -- UnitTypeName | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'ASC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'UnitTypeName', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'UnitTypeName';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT u.Id, u.UnitTypeName, u.IsActive, u.IsContainer, u.CreatedAtUtc, u.CreatedBy, u.UpdatedAtUtc, u.UpdatedBy, u.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.UnitTypes u
    WHERE (@Search IS NULL OR u.UnitTypeName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'UnitTypeName' THEN u.UnitTypeName END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'UnitTypeName' THEN u.UnitTypeName END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(u.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(u.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN u.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN u.CreatedAtUtc END DESC,
        u.UnitTypeName ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UnitTypeName, IsActive, IsContainer, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.UnitTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UnitTypeName, IsActive, IsContainer
    FROM masterdata.UnitTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY UnitTypeName;
END
GO

-- Makes this unit type THE container unit (the previous one is released).
CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_SetContainer
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id) THROW 57006, 'Unit type not found.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id AND IsActive = 0)
        THROW 57000, 'An inactive unit type cannot be the container unit.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE masterdata.UnitTypes SET IsContainer = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE IsContainer = 1 AND Id <> @Id;
        UPDATE masterdata.UnitTypes SET IsContainer = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 2. Existing "PC per container" values become container units */

DECLARE @CntType INT = (SELECT Id FROM masterdata.UnitTypes WHERE IsContainer = 1);
DECLARE @Created INT = 0;
IF @CntType IS NOT NULL
BEGIN
    INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, IsSalesUnit, IsPurchaseUnit, IsBaseUnit)
    SELECT i.Id, @CntType, i.PcPerContainer, LEFT(i.ItemCode, 46) + N'-CNT', 0, 0, 0
    FROM inventory.Items i
    WHERE i.PcPerContainer IS NOT NULL AND i.PcPerContainer >= 1
      AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.UnitTypeId = @CntType)
      AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.SkuCode = LEFT(i.ItemCode, 46) + N'-CNT');
    SET @Created = @@ROWCOUNT;
END
PRINT CAST(@Created AS NVARCHAR(10)) + ' container unit(s) created from Items.PcPerContainer';
GO

/* ================================================================== 3. Item details show the container unit */

-- Re-created: PcPerContainer comes from the container unit; the units result set flags it.
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
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, IsContainerUnit = ut.IsContainer, u.RowVersion
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

/* ================================================================== 4. Shortage plans */

IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'PcPerContainerFromUnit') IS NULL
BEGIN
    ALTER TABLE inventory.ShortageDocumentLines ADD PcPerContainerFromUnit BIT NOT NULL
        CONSTRAINT DF_ShortageDocumentLines_PcFromUnit DEFAULT (0);
    PRINT 'ShortageDocumentLines: added PcPerContainerFromUnit';
END
GO

-- Re-created from the script 24 version (transit from containers kept) + the container unit.
CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = cnt.PackingFormula,                         -- the item's Container unit, NULL when none
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           CurrentInventoryBase     = inventory.fn_StockOnHand(i.Id, @WarehouseId),
           TransitBase              = ISNULL(tr.Transit, 0),
           OutstandingOrderBase     = CASE WHEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) > 0
                                           THEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) ELSE 0 END,
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), CAST(ISNULL(s.Sold, 0) AS DECIMAL(18,4)) / NULLIF(@MonthsOfHistory, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        -- open purchase orders + invoices whose goods are still travelling
        SELECT PoOpen     = SUM(CASE WHEN dt.Code = N'PO'   THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END),
               InvPending = SUM(CASE WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
        WHERE l.ItemId = i.Id AND l.WarehouseId = @WarehouseId AND l.QuantityBase > l.ReceivedQuantityBase
          AND ((dt.Code = N'PO'   AND d.Status = 2)
            OR (dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 2))
    ) po
    OUTER APPLY
    (
        -- loaded into a container that has left the supplier and is not offloaded yet
        SELECT Transit = SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        INNER JOIN purchase.PurchaseDocumentLines pl  ON pl.Id = cl.PurchaseLineId
        WHERE cl.ItemId = i.Id AND c.Status IN (3, 4, 5)
          AND ISNULL(c.WarehouseId, pl.WarehouseId) = @WarehouseId
          AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
    ) tr
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
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    WHERE i.IsActive = 1
);
GO

-- Re-created: + PcPerContainerFromUnit.
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
           PcPerContainer = x.ItemPcPerContainer, PcPerContainerFromUnit = x.PcPerContainerFromUnit,
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

-- Re-created: the container unit always wins over a typed value.
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
                                                 PurchaseItemUnitId, PurchasePackingFormula, RequiredQty, PcPerContainer, PcPerContainerFromUnit,
                                                 MinQuantity, MaxQuantity, LastCost, Notes)
    SELECT @Id, l.LineNumber, l.ItemId, x.CurrentInventoryBase, x.TransitBase, x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, @LeadTime,
           x.PurchaseItemUnitId, x.PurchasePackingFormula,
           RequiredQty = ISNULL(l.RequiredQty,
                                CASE WHEN s.ShortageBase > 0 THEN CEILING(CAST(s.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END),
           COALESCE(x.ItemPcPerContainer, l.PcPerContainer),            -- the Container unit always wins; else what the user typed
           CAST(CASE WHEN x.ItemPcPerContainer IS NOT NULL THEN 1 ELSE 0 END AS BIT),
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

-- Re-created: lines + PcPerContainerFromUnit.
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

/* ================================================================== 5. Check */

SELECT UnitTypeName, IsContainer, IsActive FROM masterdata.UnitTypes ORDER BY IsContainer DESC, UnitTypeName;
SELECT TOP (20) i.ItemCode, PiecesPerContainer = u.PackingFormula, u.SkuCode
FROM inventory.ItemUnits u
INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId AND t.IsContainer = 1
INNER JOIN inventory.Items i ON i.Id = u.ItemId
ORDER BY i.ItemCode;
PRINT 'Script 25 applied: PC per Container comes from the item container unit.';
GO
