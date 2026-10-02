/* ================================================================== 11. Link candidates */

-- The container lines an invoice can be linked to: containers of its purchase order still Draft or Confirmed, lines of
-- the order lines the invoice still has pieces of outside any container, with something loaded and not yet invoiced
-- (by any invoice that is not cancelled). UnlinkedBase = what the invoice has of that order line outside containers.
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_LinkCandidates
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrderId INT = (SELECT d.SourceDocumentId FROM purchase.PurchaseDocuments d
                            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                            WHERE d.Id = @InvoiceId AND dt.Code = N'PINV' AND d.Status IN (1, 2));

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           cl.Id AS ContainerLineId, cl.LineNumber AS ContainerLineNumber, cl.PoLineId, cl.ItemId, i.ItemCode, i.ItemName,
           LoadedBase    = cl.QuantityBase,
           InvoicedBase  = ISNULL(q.Qty, 0),
           AvailableBase = cl.QuantityBase - ISNULL(q.Qty, 0),
           u.UnlinkedBase
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    INNER JOIN inventory.Items i      ON i.Id = cl.ItemId
    INNER JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = cl.PoLineId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    WHERE cl.PurchaseOrderId = @OrderId AND c.Status IN (1, 2) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0
    ORDER BY c.ContainerRef, cl.LineNumber;
END

GO

