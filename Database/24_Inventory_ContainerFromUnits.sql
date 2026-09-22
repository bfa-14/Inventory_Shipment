/* =====================================================================================
   Inventory_Shipment - 24: PC PER CONTAINER comes from the item's UNITS

   The shortage plan's "PC per Container" (pieces, i.e. base units, that fill one container) is no longer a
   separate field of the item. It is the Packing Formula of the item's unit whose Unit Type is "Container"
   (Item Definition -> Units & Packaging), and it stays overridable per line on a draft shortage plan:
     Default PC per Container = ItemUnits.PackingFormula of the unit typed N'Container'   (NULL without one)
     Line PC per Container    = the planner's value, else that default
   An item has at most one unit per unit type and unit type names are unique, so there is one default at most.
   Renaming the "Container" unit type breaks the link: keep the name.

   Objects: inventory.fn_Item_PcPerContainer (NEW); inventory.fn_Shortage_Live re-created (the default above);
            inventory.usp_ShortageDocument_Get re-created (lines + DefaultPcPerContainer, the item's value today);
            inventory.usp_Item_SetPurchasing / usp_Item_Get re-created without PcPerContainer.
   inventory.Items.PcPerContainer is left in place but nothing reads or writes it any more; the script lists the
   items that still hold a value there and have no Container unit, so their unit can be added.

   Requires 22, 23. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

-- The same session settings as scripts 22 and 23 (sqlcmd defaults QUOTED_IDENTIFIER to OFF).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID(N'inventory.ShortageDocumentLines', N'U') IS NULL OR COL_LENGTH(N'inventory.Items', N'WeightKg') IS NULL
BEGIN
    RAISERROR ('Run scripts 22 and 23 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. The default: the item's Container unit */

-- Pieces (base units) in one container = the Packing Formula of the item's "Container" unit; NULL without one.
CREATE OR ALTER FUNCTION inventory.fn_Item_PcPerContainer (@ItemId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT u.PackingFormula
            FROM inventory.ItemUnits u
            INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
            WHERE u.ItemId = @ItemId AND t.UnitTypeName = N'Container');
END
GO

/* ================================================================== 2. Shortage plans use it */

CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = inventory.fn_Item_PcPerContainer(i.Id),     -- the item's Container unit
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
           DefaultPcPerContainer = inventory.fn_Item_PcPerContainer(l.ItemId),   -- the Container unit today: what a cleared cell falls back to
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

/* ================================================================== 3. The item no longer has its own field */

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT           = NULL,
    @LeadTimeDays      INT           = NULL,
    @UserId            INT           = NULL,
    @WeightKg          DECIMAL(18,3) = NULL,
    @VolumeCbm         DECIMAL(18,4) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg < 0 THROW 56000, 'Weight cannot be negative.', 1;
    IF @VolumeCbm IS NOT NULL AND @VolumeCbm < 0 THROW 56000, 'Volume cannot be negative.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays,
        WeightKg = @WeightKg, VolumeCbm = @VolumeCbm, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
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
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays,
           i.WeightKg, i.VolumeCbm,
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

/* ================================================================== 4. Items to fix by hand */

DECLARE @Orphans INT = (SELECT COUNT(*) FROM inventory.Items i WHERE i.PcPerContainer IS NOT NULL AND inventory.fn_Item_PcPerContainer(i.Id) IS NULL);
IF @Orphans > 0
    PRINT CAST(@Orphans AS NVARCHAR(10)) + N' item(s) have an old PC per Container value but no Container unit - add a Container unit to them (list below).';
GO

SELECT i.ItemCode, i.ItemName, OldPcPerContainer = i.PcPerContainer
FROM inventory.Items i
WHERE i.PcPerContainer IS NOT NULL AND inventory.fn_Item_PcPerContainer(i.Id) IS NULL
ORDER BY i.ItemCode;
PRINT 'PC per Container now comes from the item''s Container unit.';
GO
