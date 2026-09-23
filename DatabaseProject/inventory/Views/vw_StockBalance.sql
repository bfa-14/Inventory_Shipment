CREATE   VIEW inventory.vw_StockBalance
AS
    SELECT m.ItemId, i.ItemCode, i.ItemName, m.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId,
           OnHandBase = SUM(m.QuantityBase), LastMovementAtUtc = MAX(m.MovementDate)
    FROM inventory.StockMovements m
    INNER JOIN inventory.Items i ON i.Id = m.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    GROUP BY m.ItemId, i.ItemCode, i.ItemName, m.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId;

GO

