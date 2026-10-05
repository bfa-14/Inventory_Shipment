/* ================================================================== 9. A purchase invoice and its containers */

-- Re-created (50) from the body of script 43: PcsPerContainer from logistics.fn_ItemPcsPerContainer.
CREATE   FUNCTION purchase.fn_PurchaseInvoice_ItemContainers (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT l.ItemId,
           InvoicedBase     = SUM(l.QuantityBase),
           LinkedBase       = SUM(CASE WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END),
           UnlinkedBase     = SUM(CASE WHEN l.ContainerLineId IS NULL THEN l.QuantityBase ELSE 0 END),
           ContainersLinked = COUNT(DISTINCT cl.ContainerId),
           PcsPerContainer  = NULLIF(MAX(ISNULL(cnt.PcsPerContainer, 0)), 0)   -- (50) no NULL in the aggregate
    FROM purchase.PurchaseDocumentLines l
    LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(l.ItemId) cnt
    WHERE l.DocumentId = @InvoiceId
    GROUP BY l.ItemId;

GO

