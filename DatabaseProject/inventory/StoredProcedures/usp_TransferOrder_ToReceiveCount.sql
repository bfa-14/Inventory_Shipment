--      status 2) whose To is one of the reader's warehouses and that have pieces on the way. 0 at once for an
--      unrestricted reader (whose count is the approvals' alone). Read-only, one row: ToReceive.
CREATE   PROCEDURE inventory.usp_TransferOrder_ToReceiveCount
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF security.fn_User_IsUnrestricted(@UserId) = 1
    BEGIN
        SELECT ToReceive = 0;
        RETURN;
    END

    DECLARE @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    INSERT INTO @Usable (WarehouseId) SELECT WarehouseId FROM security.fn_User_Warehouses(@UserId);

    -- the released orders to those warehouses first; the state (counters) only for them
    DECLARE @Orders TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Orders (Id)
    SELECT o.Id FROM inventory.TransferOrders o
    WHERE o.Status = 2 AND o.ToWarehouseId IN (SELECT WarehouseId FROM @Usable);

    SELECT ToReceive = COUNT(*)
    FROM @Orders x
    CROSS APPLY inventory.fn_TransferOrder_State(x.Id) s
    WHERE s.OnTheWayBase > 0;
END

GO

