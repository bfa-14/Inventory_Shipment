/* ================================================================== 1. The row of a created invoice */

-- What the procedures that create invoices return, one row per invoice: its item (the one of its first line), how many
-- lines and pieces, its total, and the RowVersion the page saves it with.
CREATE   FUNCTION purchase.fn_PurchaseInvoice_Row (@Id INT)
RETURNS TABLE
AS
RETURN
    SELECT d.Id, f.ItemId, i.ItemCode, i.ItemName, LineCount = x.Lines, QuantityBase = x.Qty, d.TotalAmount, d.RowVersion
    FROM purchase.PurchaseDocuments d
    CROSS APPLY (SELECT Lines = COUNT(*), Qty = ISNULL(SUM(QuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) x
    OUTER APPLY (SELECT TOP (1) ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id ORDER BY LineNumber) f
    LEFT  JOIN inventory.Items i ON i.Id = f.ItemId
    WHERE d.Id = @Id;

GO

