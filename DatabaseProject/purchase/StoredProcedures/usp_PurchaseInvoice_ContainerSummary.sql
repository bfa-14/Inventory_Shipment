/* ================================================================== 10. The containers of an invoice: summary */

-- Two result sets: 1 per item of the invoice (what it needs in containers and what is linked), 2 per linked container.
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
           MaxUnits            = COALESCE(c.MaxUnits, ct.MaxUnits),
           ShareOfContainerPct = CAST(100.0 * SUM(l.QuantityBase) / NULLIF(COALESCE(c.MaxUnits, ct.MaxUnits), 0) AS DECIMAL(9,2)),
           CanUnlink           = CAST(CASE WHEN c.Status IN (1, 2) THEN 1 ELSE 0 END AS BIT)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = l.ContainerLineId
    INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
    INNER JOIN masterdata.ContainerTypes ct  ON ct.Id = c.ContainerTypeId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    WHERE l.DocumentId = @InvoiceId
    GROUP BY c.Id, c.ContainerRef, c.ContainerNo, c.Status, cl.ItemId, i.ItemCode, c.MaxUnits, ct.MaxUnits
    ORDER BY c.ContainerRef, i.ItemCode;
END

GO

