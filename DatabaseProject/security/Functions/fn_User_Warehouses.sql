--      (masterdata.fn_Warehouse_Subtree), the lowest ticked id first, a warehouse reached twice kept once with the first
--      tick that gave it. Whatever AllWarehouses says: callers ask fn_User_IsUnrestricted first. Read by the warehouse
--      lookup (CanUse), the transfer list's filter, the to-receive count, the dialog's count.
CREATE   FUNCTION security.fn_User_Warehouses (@UserId INT)
RETURNS @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY, GrantedWarehouseId INT NOT NULL)
AS
BEGIN
    DECLARE @Tick INT = (SELECT MIN(WarehouseId) FROM security.UserWarehouses WHERE UserId = @UserId);
    WHILE @Tick IS NOT NULL
    BEGIN
        INSERT INTO @Usable (WarehouseId, GrantedWarehouseId)
        SELECT s.Id, @Tick
        FROM masterdata.fn_Warehouse_Subtree(@Tick) s
        WHERE NOT EXISTS (SELECT 1 FROM @Usable u WHERE u.WarehouseId = s.Id);

        SET @Tick = (SELECT MIN(WarehouseId) FROM security.UserWarehouses WHERE UserId = @UserId AND WarehouseId > @Tick);
    END
    RETURN;
END

GO

