--      (A2: a warehouse added under a ticked parent later is included). An On the way warehouse (90) is nobody's: 1 here,
--      a transfer being checked on its From and To (W12). NULL warehouse: 1 (nothing to refuse).
CREATE   FUNCTION security.fn_User_CanUseWarehouse (@UserId INT, @WarehouseId INT)
RETURNS BIT
AS
BEGIN
    IF @WarehouseId IS NULL OR security.fn_User_IsUnrestricted(@UserId) = 1 RETURN 1;
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsTransit = 1) RETURN 1;
    DECLARE @Id INT = @WarehouseId, @Steps INT = 0;
    WHILE @Id IS NOT NULL AND @Steps < 100      -- a cycle left by old data stops here
    BEGIN
        IF EXISTS (SELECT 1 FROM security.UserWarehouses WHERE UserId = @UserId AND WarehouseId = @Id) RETURN 1;
        SET @Id = (SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Id);
        SET @Steps += 1;
    END
    RETURN 0;
END

GO

