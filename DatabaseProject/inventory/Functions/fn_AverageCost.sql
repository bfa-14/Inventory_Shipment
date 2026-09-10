CREATE   FUNCTION inventory.fn_AverageCost (@ItemId INT)
RETURNS DECIMAL(18,6)
AS
BEGIN
    RETURN (SELECT CASE WHEN SUM(QuantityBase) > 0 THEN SUM(QuantityBase * ISNULL(UnitCostBase, 0)) / SUM(QuantityBase) END
            FROM inventory.StockMovements
            WHERE ItemId = @ItemId AND QuantityBase > 0 AND IsReversal = 0);
END