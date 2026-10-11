CREATE   PROCEDURE inventory.usp_Item_StockBalance
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId) RETURN;

    SELECT b.WarehouseId, b.WarehouseCode, b.WarehouseName, w.IsActive AS WarehouseIsActive,
           b.BranchId, br.BranchCode, br.BranchName,
           b.OnHandBase, b.LastMovementAtUtc,
           AverageCost    = i.AverageCost,
           InventoryValue = CONVERT(DECIMAL(18,2), CASE WHEN b.OnHandBase > 0 THEN b.OnHandBase * ISNULL(i.AverageCost, 0) ELSE 0 END)
    FROM inventory.vw_StockBalance b
    INNER JOIN inventory.Items i      ON i.Id = b.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = b.WarehouseId
    INNER JOIN masterdata.Branches br  ON br.Id = b.BranchId
    WHERE b.ItemId = @ItemId
    ORDER BY b.OnHandBase DESC, b.WarehouseCode;
END

GO

