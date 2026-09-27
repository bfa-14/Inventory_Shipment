-- the part still in stock changes the inventory value (moving average), the part already sold goes to COGS.
-- Then the item costs are replayed (exact average, last / FOB cost from the latest receipt).
CREATE   PROCEDURE logistics.usp_ContainerCharge_ApplyCost
    @ChargeId INT,
    @Sign     SMALLINT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Ref NVARCHAR(30), @BranchId INT, @WarehouseId INT;
    SELECT @ContainerId = c.Id, @Ref = c.ContainerRef, @BranchId = c.BranchId, @WarehouseId = c.WarehouseId
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @WarehouseId IS NULL THROW 70010, 'The container has no offloading warehouse.', 1;

    DECLARE @Adj TABLE (LineId INT PRIMARY KEY, ItemId INT, Delta DECIMAL(18,2), Inv DECIMAL(18,2) NULL);
    INSERT INTO @Adj (LineId, ItemId, Delta)
    SELECT cl.Id, cl.ItemId, @Sign * a.AmountBase
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
    WHERE a.ChargeId = @ChargeId AND a.AmountBase <> 0;

    -- per item: what the container brought, and how much of it can still be in stock (capped by the warehouse stock)
    DECLARE @Items TABLE (ItemId INT PRIMARY KEY, Received DECIMAL(18,6), Remaining DECIMAL(18,6), CompanyOnHand DECIMAL(18,6));
    INSERT INTO @Items (ItemId, Received, Remaining, CompanyOnHand)
    SELECT x.ItemId, x.Received,
           CASE WHEN oh.Q < x.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END ELSE x.Received END,
           inventory.fn_StockOnHand(x.ItemId, NULL)
    FROM (SELECT cl.ItemId, Received = SUM(ISNULL(cl.ReceivedQuantityBase, 0))
          FROM logistics.ContainerLines cl
          WHERE cl.ContainerId = @ContainerId
          GROUP BY cl.ItemId) x
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, @WarehouseId)) oh
    WHERE x.ItemId IN (SELECT ItemId FROM @Adj);

    UPDATE a
    SET Inv = CASE WHEN i.CompanyOnHand <= 0 OR i.Received <= 0 THEN 0 ELSE ROUND(a.Delta * i.Remaining / i.Received, 2) END
    FROM @Adj a
    INNER JOIN @Items i ON i.ItemId = a.ItemId;

    INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
    SELECT SYSUTCDATETIME(), a.ItemId, @WarehouseId, @BranchId, k.Kind, k.Amount, N'CNTCHARGE', @ChargeId, @Ref, NULL, @UserId
    FROM @Adj a
    CROSS APPLY (VALUES (N'Inventory', ISNULL(a.Inv, 0)), (N'COGS', a.Delta - ISNULL(a.Inv, 0))) k (Kind, Amount)
    WHERE k.Amount <> 0;

    DECLARE @ItemId INT;
    DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM @Adj;
    OPEN items;
    FETCH NEXT FROM items INTO @ItemId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC inventory.usp_Item_RebuildCosts @ItemId;
        FETCH NEXT FROM items INTO @ItemId;
    END
    CLOSE items;
    DEALLOCATE items;
END

GO

