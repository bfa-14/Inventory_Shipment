/* -- what the warning dialog shows: the invoice's shortages, each with its verdict ------------ */
CREATE   PROCEDURE sales.usp_SalesDocument_StockCheck
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id)
        THROW 64006, 'Document not found.', 1;

    -- Only an outgoing document (an invoice) can run short.
    SELECT x.ItemId, i.ItemCode, i.ItemName, x.WarehouseId, w.WarehouseCode, w.WarehouseName,
           CurrentQty  = inventory.fn_StockOnHand(x.ItemId, x.WarehouseId),
           QuantitySold = x.Qty,
           Allowed      = p.Allowed,
           PolicySource = p.Source
    FROM (SELECT l.ItemId, l.WarehouseId, SUM(l.QuantityBase) AS Qty
          FROM sales.SalesDocumentLines l
          INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
          INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.StockDirection = -1
          WHERE l.DocumentId = @Id
          GROUP BY l.ItemId, l.WarehouseId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    CROSS APPLY sales.fn_OutOfStockPolicy(x.WarehouseId) p
    WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
    ORDER BY i.ItemCode, w.WarehouseCode;
END

GO

