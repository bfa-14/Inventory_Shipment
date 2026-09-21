CREATE   FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
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

