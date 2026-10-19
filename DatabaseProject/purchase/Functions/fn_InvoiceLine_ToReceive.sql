/* ================================================================== 9. Invoice lines: still to receive */

-- One row per line of a purchase invoice NOT linked to a container (the linked ones are received with their
-- containers). ToReceiveBase = invoiced - received - on draft goods receipts that point to the line, never below 0;
-- received = ReceivedQuantityBase (the pieces matched to the line, for an invoice that uses goods receipts or is
-- shipped in containers). 0 when the invoice is not posted or closed, and for an invoice posted before goods receipts
-- without "Shipped in containers" (UsesGoodsReceipts = 0, ReceiptMode 1): its goods entered stock when it was posted.
CREATE   FUNCTION purchase.fn_InvoiceLine_ToReceive (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT InvoiceId           = d.Id,
           InvoiceLineId       = l.Id,
           l.LineNumber, l.ItemId, l.ItemUnitId, l.PackingFormula, l.WarehouseId, l.ExpiryDate,
           PoLineId            = l.SourceLineId,
           d.SupplierId,
           InvoiceStatus       = d.Status,
           ReceivedAtPosting   = CAST(CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1 ELSE 0 END AS BIT),
           InvoicedBase        = l.QuantityBase,
           ReceivedBase        = l.ReceivedQuantityBase,
           ReturnedBase        = l.ReturnedQuantityBase,
           InDraftReceiptsBase = q.InDrafts,
           ToReceiveBase       = CASE WHEN d.Status NOT IN (2, 4) OR (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1) THEN 0
                                      WHEN l.QuantityBase - l.ReceivedQuantityBase - q.InDrafts > 0
                                      THEN l.QuantityBase - l.ReceivedQuantityBase - q.InDrafts
                                      ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt       ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
    INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id AND l.ContainerLineId IS NULL
    CROSS APPLY (SELECT InDrafts = ISNULL((SELECT SUM(gl.QuantityBase)
                                           FROM purchase.GoodsReceiptLines gl
                                           INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                           WHERE gl.InvoiceLineId = l.Id AND g.Status = 1), 0)) q
    WHERE d.Id = @InvoiceId;

GO

