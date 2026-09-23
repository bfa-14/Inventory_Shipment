CREATE   FUNCTION inventory.fn_StockOnHand (@ItemId INT, @WarehouseId INT)
RETURNS INT
AS
BEGIN
    RETURN ISNULL((SELECT SUM(QuantityBase) FROM inventory.StockMovements
                   WHERE ItemId = @ItemId AND (@WarehouseId IS NULL OR WarehouseId = @WarehouseId)), 0);
END

GO

