/* ================================================================== 2. usp_ContainerCharge_ApplyCost */

-- A charge that enters (@Sign = 1) or leaves (@Sign = -1) the cost of goods already received: the part still in the
-- company's stock changes the average cost, the part already sold goes to cost of sales; then the items' costs are
-- replayed. Re-created (118) from the body of script 102: its lines and their stock parts come from
-- logistics.fn_ContainerCharge_StockShare (the rule it held, moved there unchanged); the caps of a cancel stay here.
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

    -- (118) EACH LINE'S DELTA AND ITS STOCK PART FROM logistics.fn_ContainerCharge_StockShare: the rule that was written
    --       here (89: the company's stock of the item, capped at what the container brought), in one place, which the
    --       post preview (usp_ContainerCharge_PostPreview) reads too, so the confirmation says what the post will do.
    DECLARE @Adj TABLE (LineId INT PRIMARY KEY, ItemId INT, Delta DECIMAL(18,2), Inv DECIMAL(18,2) NULL);
    INSERT INTO @Adj (LineId, ItemId, Delta, Inv)
    SELECT s.LineId, s.ItemId, s.Delta, s.Inv
    FROM logistics.fn_ContainerCharge_StockShare(@ChargeId, @Sign) s;

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

    -- (102) THE MIRROR FOR A DEDUCTION: its cancel puts back into stock no more than its posting took out of it, per item
    --       (pieces received since would otherwise get a share of it); the rest goes back to cost of sales. The cap above
    --       does nothing for a deduction (what it took out is negative).
    IF @Sign = -1 AND @AdjustedAfter = 1 AND EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @ChargeId AND AmountBase < 0)
    BEGIN
        DECLARE @Back TABLE (ItemId INT PRIMARY KEY, TookOut DECIMAL(18,2) NOT NULL, PutBack DECIMAL(18,2) NOT NULL);
        INSERT INTO @Back (ItemId, TookOut, PutBack)
        SELECT a.ItemId,
               -ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                        WHERE c.SourceKind = N'CNTCHARGE' AND c.SourceId = @ChargeId AND c.Kind = N'Inventory'
                          AND c.ItemId = a.ItemId), 0),
               SUM(ISNULL(a.Inv, 0))
        FROM @Adj a
        GROUP BY a.ItemId;
        UPDATE @Back SET TookOut = 0 WHERE TookOut < 0;

        UPDATE a
        SET Inv = ROUND(ISNULL(a.Inv, 0) * b.TookOut / b.PutBack, 2)
        FROM @Adj a
        INNER JOIN @Back b ON b.ItemId = a.ItemId
        WHERE b.PutBack > b.TookOut;                                     -- PutBack > TookOut >= 0: never a division by 0

        ;WITH d AS (SELECT a.LineId, Diff = b.TookOut - SUM(ISNULL(a.Inv, 0)) OVER (PARTITION BY a.ItemId),
                           Rn = ROW_NUMBER() OVER (PARTITION BY a.ItemId ORDER BY ABS(a.Delta) DESC, a.LineId)
                    FROM @Adj a
                    INNER JOIN @Back b ON b.ItemId = a.ItemId
                    WHERE b.PutBack > b.TookOut)
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

