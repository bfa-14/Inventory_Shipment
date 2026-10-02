-- (its Container unit, script 25; NULL when the item has none).
CREATE   FUNCTION purchase.fn_PurchaseInvoice_ItemContainers (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT l.ItemId,
           InvoicedBase     = SUM(l.QuantityBase),
           LinkedBase       = SUM(CASE WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END),
           UnlinkedBase     = SUM(CASE WHEN l.ContainerLineId IS NULL THEN l.QuantityBase ELSE 0 END),
           ContainersLinked = COUNT(DISTINCT cl.ContainerId),
           PcsPerContainer  = MAX(cnt.PackingFormula)
    FROM purchase.PurchaseDocumentLines l
    LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1 AND u.PackingFormula > 0
                 ORDER BY u.Id) cnt
    WHERE l.DocumentId = @InvoiceId
    GROUP BY l.ItemId;

GO

