/* ================================================================== 4. Used: by transactions, or by stock levels */

-- (91) A WAREHOUSE USED BY STOCK OR A DOCUMENT: the body of masterdata.fn_Warehouse_IsUsed as script 90 left it, moved
--      here unchanged. fn_Warehouse_IsUsed (re-created below) = this OR stock levels; the used-parent refusal reads both
--      to give a warehouse used only through its levels its own sentence. A later script adds its document tables HERE.
CREATE   FUNCTION masterdata.fn_Warehouse_IsUsedInTransactions (@WarehouseId INT)
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

