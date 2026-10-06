SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   62: Shortage plan - a parent warehouse counts its whole tree
   --------------------------------------------------------------------------------------------------
   A shortage plan may be made for a PARENT warehouse (one with warehouses under it). Its figures
   are then those of the parent and every warehouse below it, at any depth: stock on hand, sales in
   the history months, open purchase orders and invoices still travelling, and containers in
   transit. A warehouse with nothing under it counts only itself, exactly as before.

     inventory.fn_Shortage_Live   the warehouse filter is the warehouse's tree, not the warehouse alone
                                  (used by usp_Shortage_Calculate and usp_ShortageDocument_WriteLines)
   ================================================================================================== */

IF OBJECT_ID(N'inventory.fn_Shortage_Live', N'IF') IS NULL
BEGIN
    RAISERROR ('The shortage scripts must run before script 62.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    /* (62) THE WAREHOUSE AND EVERY WAREHOUSE UNDER IT. A plan for a parent counts the stock, sales,
       orders and containers of its whole tree; a warehouse with nothing under it is just itself.
       The depth guard stops a cycle left by older data instead of recursing for ever. */
    WITH tree AS
    (
        SELECT w.Id, 0 AS Depth FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId
        UNION ALL
        SELECT w.Id, t.Depth + 1 FROM masterdata.Warehouses w INNER JOIN tree t ON w.ParentId = t.Id WHERE t.Depth < 20
    )
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = cnt.PackingFormula,                         -- the item's Container unit, NULL when none
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           CurrentInventoryBase     = ISNULL((SELECT SUM(m.QuantityBase) FROM inventory.StockMovements m
                                              WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t)), 0),
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
        WHERE l.ItemId = i.Id AND l.WarehouseId IN (SELECT t.Id FROM tree t) AND l.QuantityBase > l.ReceivedQuantityBase
          AND ((dt.Code = N'PO'   AND d.Status = 2)
            OR (dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 2
                AND NOT EXISTS (SELECT 1 FROM logistics.ContainerLines xcl INNER JOIN logistics.Containers xc ON xc.Id = xcl.ContainerId
                                WHERE xcl.Id = l.ContainerLineId AND xc.Status IN (6, 7))))
    ) po
    OUTER APPLY
    (
        -- loaded into a container that has left the supplier and is not offloaded yet
        SELECT Transit = SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        INNER JOIN purchase.PurchaseDocumentLines pl  ON pl.Id = cl.PoLineId
        WHERE cl.ItemId = i.Id AND c.Status IN (3, 4, 5)
          AND pl.WarehouseId IN (SELECT t.Id FROM tree t)                  -- the order's warehouse, like the open order / invoice quantities
          AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
    ) tr
    OUTER APPLY
    (
        SELECT Sold = SUM(-m.QuantityBase)
        FROM inventory.StockMovements m
        WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t) AND m.DocumentFamily = N'Sales'
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

PRINT 'Script 62 applied: a shortage plan for a parent warehouse counts its whole tree.';
GO

SET NOEXEC OFF;
GO
