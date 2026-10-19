/* ================================================================== 3. The row of a created invoice: + how many items */

-- Re-created (63) from the body of script 45: + ItemCount (more than 1 for an invoice of several items).
CREATE   FUNCTION purchase.fn_PurchaseInvoice_Row (@Id INT)
RETURNS TABLE
AS
RETURN
    SELECT d.Id, f.ItemId, i.ItemCode, i.ItemName, LineCount = x.Lines, QuantityBase = x.Qty, d.TotalAmount, d.RowVersion,
           ItemCount = x.Items   -- (63)
    FROM purchase.PurchaseDocuments d
    CROSS APPLY (SELECT Lines = COUNT(*), Qty = ISNULL(SUM(QuantityBase), 0), Items = COUNT(DISTINCT ItemId)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) x
    OUTER APPLY (SELECT TOP (1) ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id ORDER BY LineNumber) f
    LEFT  JOIN inventory.Items i ON i.Id = f.ItemId
    WHERE d.Id = @Id;

GO

