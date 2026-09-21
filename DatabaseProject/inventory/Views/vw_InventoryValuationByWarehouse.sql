CREATE   VIEW inventory.vw_InventoryValuationByWarehouse
AS
    SELECT b.ItemId, b.ItemCode, b.ItemName, b.WarehouseId, b.WarehouseCode, b.WarehouseName, b.BranchId,
           b.OnHandBase, i.AverageCost,
           InventoryValue = CAST(b.OnHandBase * i.AverageCost AS DECIMAL(18,2))
    FROM inventory.vw_StockBalance b
    INNER JOIN inventory.Items i ON i.Id = b.ItemId;
GO

