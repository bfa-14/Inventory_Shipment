
/* ==================================================================================================
   66: A warehouse already used in transactions cannot become a parent
   --------------------------------------------------------------------------------------------------
   Stock is kept only in the warehouses at the bottom of the tree (script 65). A warehouse that has
   been used - stock moved in or out of it, or named on a document - would hold that history as a
   parent, where no document may reach it any more. So it may not be chosen as the parent of another
   warehouse.

   "Used" means named by any of: a stock movement, an Inventory In / Out document or line, a sales
   or purchase document or line, a container, a cost adjustment, a landed cost adjustment line, or
   the out-of-stock sales log. Shortage plans do not count (a plan may be made for a parent, script
   62), nor an item's default warehouse or the import log.

     masterdata.fn_Warehouse_IsUsed      new: 1 when the warehouse is used as above
     masterdata.usp_Warehouse_Create     refuses a used parent (52000)
     masterdata.usp_Warehouse_Update     refuses a used parent when the parent CHANGES (a warehouse
                                         already under a used one keeps its place)
     masterdata.usp_Warehouse_Lookup     new column IsUsed, so the Parent picker can grey them out

   Each procedure is re-created from its current body with only these changes.
   ================================================================================================== */

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
                THEN 1 ELSE 0 END;
END

GO

