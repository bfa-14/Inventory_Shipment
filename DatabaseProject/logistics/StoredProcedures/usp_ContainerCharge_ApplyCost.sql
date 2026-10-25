/* ================================================================== 2. logistics.usp_ContainerCharge_ApplyCost */

-- A charge that enters (@Sign = 1) or leaves (@Sign = -1) the cost of goods already offloaded:
-- the part still in stock changes the inventory value (moving average), the part already sold goes to COGS.
-- Then the item costs are replayed (exact average, last / FOB cost from the latest receipt).
-- Re-created (89) from the body of script 27: THE PART STILL IN STOCK IS CAPPED BY THE COMPANY'S STOCK of the item, every
-- warehouse, as the goods receipt true-up (GRNCOST) does - no longer by the receiving warehouse's: the average is
-- company-wide, and goods moved to another warehouse (an Inventory Out + In, a transfer) are still held. A CANCEL OF A
-- CHARGE POSTED AFTER THE RECEIPT NEVER TAKES MORE OUT OF STOCK THAN ITS POSTING PUT IN, per item. The rows keep the
-- receiving warehouse and the container's branch, for the reports.
CREATE   PROCEDURE logistics.usp_ContainerCharge_ApplyCost
    @ChargeId INT,
    @Sign     SMALLINT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Ref NVARCHAR(30), @BranchId INT, @WarehouseId INT, @AdjustedAfter BIT;
    SELECT @ContainerId = c.Id, @Ref = c.ContainerRef, @BranchId = c.BranchId, @WarehouseId = c.WarehouseId,
           @AdjustedAfter = ch.AdjustedAfterOffload                                  -- (89) for the cancel's cap
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

    -- per item: what the container brought, and how much of it can still be in stock - (89) capped by the COMPANY's
    -- stock of the item, every warehouse (was: the receiving warehouse's stock)
    DECLARE @Items TABLE (ItemId INT PRIMARY KEY, Received DECIMAL(18,6), Remaining DECIMAL(18,6), CompanyOnHand DECIMAL(18,6));
    INSERT INTO @Items (ItemId, Received, Remaining, CompanyOnHand)
    SELECT x.ItemId, x.Received,
           CASE WHEN oh.Q < x.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END ELSE x.Received END,
           oh.Q
    FROM (SELECT cl.ItemId, Received = SUM(ISNULL(cl.ReceivedQuantityBase, 0))
          FROM logistics.ContainerLines cl
          WHERE cl.ContainerId = @ContainerId
          GROUP BY cl.ItemId) x
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, NULL)) oh                -- (89) NULL: every warehouse
    WHERE x.ItemId IN (SELECT ItemId FROM @Adj);

    UPDATE a
    SET Inv = CASE WHEN i.CompanyOnHand <= 0 OR i.Received <= 0 THEN 0 ELSE ROUND(a.Delta * i.Remaining / i.Received, 2) END
    FROM @Adj a
    INNER JOIN @Items i ON i.ItemId = a.ItemId;

    -- (89) A CANCEL NEVER TAKES MORE OUT OF STOCK THAN ITS POSTING PUT IN, per item. The stock part above is worked out
    --      again with today's stock - right when goods were sold since the posting (they took their share of the charge
    --      to cost of sales at the average) - but it can exceed what the posting put in: a charge posted before script 89
    --      (the receiving warehouse's stock decided then), or pieces of other purchases received since (they count as the
    --      container's). Taking out more would push the average below where it was before the charge. It is lowered to
    --      the posting's Inventory rows, in proportion over the item's lines, the cents on the line with the largest
    --      amount; the rest goes to cost of sales. A charge frozen in the goods' cost at the receipt (AppliedAtOffload)
    --      put all of it in stock: no cap.
    IF @Sign = -1 AND @AdjustedAfter = 1
    BEGIN
        DECLARE @Cap TABLE (ItemId INT PRIMARY KEY, Posted DECIMAL(18,2) NOT NULL, TakenOut DECIMAL(18,2) NOT NULL);
        INSERT INTO @Cap (ItemId, Posted, TakenOut)
        SELECT a.ItemId,
               ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                       WHERE c.SourceKind = N'CNTCHARGE' AND c.SourceId = @ChargeId AND c.Kind = N'Inventory'
                         AND c.ItemId = a.ItemId), 0),
               -SUM(ISNULL(a.Inv, 0))
        FROM @Adj a
        GROUP BY a.ItemId;
        UPDATE @Cap SET Posted = 0 WHERE Posted < 0;

        UPDATE a
        SET Inv = -ROUND(-ISNULL(a.Inv, 0) * c.Posted / c.TakenOut, 2)
        FROM @Adj a
        INNER JOIN @Cap c ON c.ItemId = a.ItemId
        WHERE c.TakenOut > c.Posted;                                     -- TakenOut > Posted >= 0: never a division by 0

        ;WITH d AS (SELECT a.LineId, Diff = -c.Posted - SUM(ISNULL(a.Inv, 0)) OVER (PARTITION BY a.ItemId),
                           Rn = ROW_NUMBER() OVER (PARTITION BY a.ItemId ORDER BY ABS(a.Delta) DESC, a.LineId)
                    FROM @Adj a
                    INNER JOIN @Cap c ON c.ItemId = a.ItemId
                    WHERE c.TakenOut > c.Posted)
        UPDATE a SET Inv = ISNULL(a.Inv, 0) + d.Diff
        FROM @Adj a
        INNER JOIN d ON d.LineId = a.LineId
        WHERE d.Rn = 1 AND d.Diff <> 0;
    END

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

