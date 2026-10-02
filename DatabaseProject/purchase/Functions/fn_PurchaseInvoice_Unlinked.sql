-- the invoice line it is linked to must come from the same one.
CREATE   FUNCTION purchase.fn_PurchaseInvoice_Unlinked (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT PoLineId = l.SourceLineId, l.ItemId, UnlinkedBase = SUM(l.QuantityBase)
    FROM purchase.PurchaseDocumentLines l
    WHERE l.DocumentId = @InvoiceId AND l.ContainerLineId IS NULL AND l.SourceLineId IS NOT NULL
    GROUP BY l.SourceLineId, l.ItemId;

GO

