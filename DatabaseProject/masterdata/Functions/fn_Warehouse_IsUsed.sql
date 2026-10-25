-- not tested: every posting writes ledger rows in From and in the On the way warehouse, which the ledger test already
-- covers, and To is named on the order.
CREATE   FUNCTION masterdata.fn_Warehouse_IsUsed (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM inventory.StockMovements          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocumentLines      WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocuments          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocuments              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines    WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocuments        WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM logistics.Containers              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.CostAdjustments         WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.LandedCostAdjustmentLines WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.OutOfStockSaleAudit         WHERE WarehouseId = @WarehouseId)
                  -- (72) a goods receipt names it: "Receive into" (a draft too) or a line's warehouse
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceipts            WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines        WHERE WarehouseId = @WarehouseId)
                  -- (90) a transfer order names it, as the source or the destination (a draft too)
                  OR EXISTS (SELECT 1 FROM inventory.TransferOrders          WHERE FromWarehouseId = @WarehouseId OR ToWarehouseId = @WarehouseId)
                THEN 1 ELSE 0 END;
END

GO

