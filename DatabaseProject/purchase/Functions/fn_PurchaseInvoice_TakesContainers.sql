/* ================================================================== 1. Helpers */

-- 1 when @InvoiceId is a purchase invoice of @PurchaseOrderId that can still take containers: a draft, or a posted
-- invoice shipped in containers (receipt mode 2). Posting such an invoice may close its order (fully invoiced); the
-- container procedures accept that closed order when they are called for this invoice (@ForInvoiceId).
CREATE   FUNCTION purchase.fn_PurchaseInvoice_TakesContainers (@PurchaseOrderId INT, @InvoiceId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN @InvoiceId IS NOT NULL
                 AND EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                             INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                             WHERE d.Id = @InvoiceId AND dt.Code = N'PINV' AND d.SourceDocumentId = @PurchaseOrderId
                               AND (d.Status = 1 OR (d.Status = 2 AND d.ReceiptMode = 2)))
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END;
END

GO

