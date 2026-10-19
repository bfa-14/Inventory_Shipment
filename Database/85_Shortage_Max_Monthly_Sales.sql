SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   85: Shortages - Expected Monthly Sales is the busiest month of the history
   --------------------------------------------------------------------------------------------------
   "Load items" (and Calculate, Recalculate) worked out an item's Expected Monthly Sales as the AVERAGE:
   what was sold in the last N months of history, divided by N. It is now the HIGHEST month: the history
   is cut into N blocks of one month, counted back from today, and the block with the most net sales
   (sales less returns) gives the figure. Example, 3 months of history with 10, 40 and 25 pieces sold:
   40 (it was 25).

     inventory.fn_Shortage_Live   ExpectedMonthlySalesBase = the highest month (SoldInPeriodBase unchanged:
                                  the total of the whole history)

   Plans already saved keep the figures they were written with until they are recalculated; a figure
   typed by hand ("manual") is never touched. Re-created from its current body with only this change.
   Idempotent.
   ================================================================================================== */

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
           -- (85) the HIGHEST month of the history, not the average: plan for the busiest month seen.
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), ISNULL(mx.MaxMonthSold, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        -- (65) rule 25: open and closed orders still to receive + invoices without an order not received yet
        SELECT PoOpen     = SUM(CASE WHEN dt.Code = N'PO'   THEN ISNULL(pp.OutstandingBase, 0) ELSE 0 END),
               InvPending = SUM(CASE WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
        OUTER APPLY (SELECT p.OutstandingBase FROM purchase.fn_PoLine_Progress(d.Id) p WHERE p.PoLineId = l.Id) pp
        WHERE l.ItemId = i.Id AND l.WarehouseId IN (SELECT t.Id FROM tree t)
          AND ((dt.Code = N'PO'   AND d.Status IN (2, 4))
            OR (dt.Code = N'PINV' AND d.Status IN (2, 4) AND d.UsesGoodsReceipts = 1 AND l.SourceLineId IS NULL
                AND l.QuantityBase > l.ReceivedQuantityBase))
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
        /* (85) THE BUSIEST MONTH. The same history, cut into @MonthsOfHistory blocks of one month counted
           back from tonight (block 0 = the last month up to today included, block 1 = the month before it...),
           each up to the same day of the next one, so no day counts twice; the
           net sales of each (sales less returns), and the highest of them. A month without sales counts 0. */
        SELECT MaxMonthSold = MAX(b.Sold)
        FROM (SELECT k.n, Sold = ISNULL((SELECT SUM(-m.QuantityBase)
                                         FROM inventory.StockMovements m
                                         WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t)
                                           AND m.DocumentFamily = N'Sales'
                                           AND m.MovementDate >= DATEADD(MONTH, -(k.n + 1), DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)))
                                           AND m.MovementDate <  DATEADD(MONTH, -k.n, DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)))), 0)
              FROM (SELECT TOP (CASE WHEN @MonthsOfHistory > 0 THEN @MonthsOfHistory ELSE 1 END)
                           n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
                    FROM (VALUES (0),(0),(0),(0),(0),(0)) a (x) CROSS JOIN (VALUES (0),(0),(0),(0),(0),(0)) b (x)) k
        ) b
    ) mx
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

PRINT 'Script 85 applied: Expected Monthly Sales is the busiest month of the history.';
GO
