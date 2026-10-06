SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   59: Item purchase orders
   --------------------------------------------------------------------------------------------------
   The item card's "Purchase Orders" quick link: every purchase order that has the item on it, newest
   first, with what the order asks for of THIS item - ordered, received, and still to come.

     inventory.usp_Item_PurchaseOrders   @ItemId -> one row per order (its lines of the item added up)

   STILL TO COME is counted on an open (Posted) order only: a draft has not been sent, a cancelled or
   closed order will not deliver any more, so their remainder is not stock on its way.
   ================================================================================================== */

IF OBJECT_ID(N'purchase.PurchaseDocuments', N'U') IS NULL
BEGIN
    RAISERROR ('The purchase scripts must run before script 59.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_PurchaseOrders
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

PRINT 'Script 59 applied: item purchase orders.';
GO

SET NOEXEC OFF;
GO
