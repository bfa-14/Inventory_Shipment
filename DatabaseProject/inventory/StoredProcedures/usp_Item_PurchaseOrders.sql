/* ================================================================== 8. Item Definition > Purchase orders */

-- Re-created (77) from the body of script 65: + InvoicingStatus of each order (the whole order's, not only this
-- item's lines: it is the order's status). Still to come is unchanged.
CREATE   PROCEDURE inventory.usp_Item_PurchaseOrders
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.Status AS StatusCode,
           s.PartyCode AS SupplierCode, s.PartyName AS SupplierName, br.BranchName,
           c.CurrencyCode, c.DecimalPlaces,
           x.OrderedBase, x.ReceivedBase, x.InvoicedBase, x.ShortBase,                       -- (65) received = goods received
           OutstandingBase = CASE WHEN d.Status IN (2, 4) THEN x.OutstandingBase ELSE 0 END, -- (65) rule 25
           x.Amount,
           inv.InvoicingStatus                                                               -- (77) the ORDER's, every item
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
    CROSS APPLY (SELECT OrderedBase = SUM(l.QuantityBase), ReceivedBase = SUM(l.GoodsReceivedBase),
                        InvoicedBase = SUM(l.ReceivedQuantityBase), ShortBase = SUM(l.GoodsShortBase),
                        OutstandingBase = SUM(p.OutstandingBase), Amount = SUM(l.LineTotal)
                 FROM purchase.PurchaseDocumentLines l
                 CROSS APPLY purchase.fn_PoLine_Progress(l.DocumentId) p
                 WHERE l.DocumentId = d.Id AND l.ItemId = @ItemId AND p.PoLineId = l.Id) x
    INNER JOIN masterdata.Parties s    ON s.Id = d.SupplierId
    INNER JOIN masterdata.Branches br  ON br.Id = d.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(d.Id) inv
    WHERE x.OrderedBase IS NOT NULL
    ORDER BY d.DocumentDate DESC, d.Id DESC;
END

GO

