CREATE   PROCEDURE inventory.usp_Item_PurchaseOrders
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.Status AS StatusCode,
           s.PartyCode AS SupplierCode, s.PartyName AS SupplierName, br.BranchName,
           c.CurrencyCode, c.DecimalPlaces,
           x.OrderedBase, x.ReceivedBase,
           OutstandingBase = CASE WHEN d.Status = 2 AND x.OrderedBase > x.ReceivedBase THEN x.OrderedBase - x.ReceivedBase ELSE 0 END,
           x.Amount
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
    CROSS APPLY (SELECT OrderedBase = SUM(l.QuantityBase), ReceivedBase = SUM(l.ReceivedQuantityBase), Amount = SUM(l.LineTotal)
                 FROM purchase.PurchaseDocumentLines l
                 WHERE l.DocumentId = d.Id AND l.ItemId = @ItemId) x
    INNER JOIN masterdata.Parties s    ON s.Id = d.SupplierId
    INNER JOIN masterdata.Branches br  ON br.Id = d.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE x.OrderedBase IS NOT NULL
    ORDER BY d.DocumentDate DESC, d.Id DESC;
END

GO

