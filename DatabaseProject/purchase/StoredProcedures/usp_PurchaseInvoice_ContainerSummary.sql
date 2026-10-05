-- pieces per container (its Container unit); MaxUnits is no longer returned (PcsPerContainer instead).
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_ContainerSummary
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.ItemId, i.ItemCode, i.ItemName, s.InvoicedBase, s.PcsPerContainer,
           ContainersNeeded = CAST(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer AS DECIMAL(18,2)),
           FullContainers   = s.InvoicedBase / s.PcsPerContainer,
           PartialPieces    = s.InvoicedBase % s.PcsPerContainer,
           s.LinkedBase, s.ContainersLinked, s.UnlinkedBase
    FROM purchase.fn_PurchaseInvoice_ItemContainers(@InvoiceId) s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId
    ORDER BY i.ItemCode;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status, cl.ItemId, i.ItemCode,
           QuantityBase        = SUM(l.QuantityBase),
           PcsPerContainer     = p.PcsPerContainer,
           ShareOfContainerPct = CAST(100.0 * SUM(l.QuantityBase) / p.PcsPerContainer AS DECIMAL(9,2)),
           CanUnlink           = CAST(CASE WHEN c.Status IN (1, 2) THEN 1 ELSE 0 END AS BIT)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = l.ContainerLineId
    INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) p
    WHERE l.DocumentId = @InvoiceId
    GROUP BY c.Id, c.ContainerRef, c.ContainerNo, c.Status, cl.ItemId, i.ItemCode, p.PcsPerContainer
    ORDER BY c.ContainerRef, i.ItemCode;
END

GO

