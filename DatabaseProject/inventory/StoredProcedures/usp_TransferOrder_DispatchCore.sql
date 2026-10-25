/* ================================================================== 13 (continued). Transfer orders: dispatch, receipt, close, cancel, reverse, ETA and return (2.3.8.13-2.3.8.20) */

/* The procedures that move stock, and the ones that settle or undo what moved: a dispatch (TRD) takes pieces out of From
   into the On the way warehouse of the destination branch, a transfer receipt (TRR) takes them from there into To (and
   writes off what will not arrive), "Dispatch and receive" posts both in one transaction; "Nothing more will be sent"
   settles what is left to dispatch, Cancel order cancels an order that dispatched nothing, Reverse undoes one whole
   posting in place, Change ETA moves a dispatch's ETA, Create return makes a new draft in the other direction.

   THE LEDGER ROWS (business-context 4.13, T29): family Transfer, type TRD or TRR, the posting's id, line id and number;
   reasons TRF_OUT on the two legs of a dispatch, TRF_IN on the two legs of a receipt, TRF_LOSS on a write-off - never
   family Sales (Shortages reads that family as sales). Every row is stamped CreatedBy = the acting user (G4), never a
   value copied from another row, and no INSERT into the ledger uses OUTPUT.

   COST-NEUTRAL (FB rule 34): each row carries the item's average cost of the moment (Items.AverageCost) for information,
   frozen on the dispatch line and carried to its receipt; no posting here calls inventory.usp_Item_ApplyReceipts, so
   no transfer moves an average, last or FOB cost. The company's stock only changes by a write-off (TRF_LOSS, at the
   average at receipt); the cost replay reads the incoming transfer legs at the running average (script 90, 14).

   THE LOCKS (T31): every action reads the order's header first WITH (UPDLOCK, HOLDLOCK), so two users acting on one order
   queue up on it and its counters (TransferOrderLines.DispatchedBase, ReceivedBase, LostBase, NotSentBase and the
   dispatch lines' SettledBase) only move under that lock; a dispatch also takes the application lock of its source
   warehouse, so two dispatches from one warehouse never both pass the stock check. A dispatch and a sale from the same
   warehouse at the same instant can still both pass it, as two sales can today.

   THE CORES (DispatchCore, ReceiveCore) post without a transaction of their own: their callers (Dispatch, Receive,
   Dispatch and receive) hold one and the order's lock, have checked the RowVersion and the action's first row of
   inventory.fn_TransferOrder_Blocks, and write the order's header stamp and the one audit row of the action. */

/* 13.16 POST A DISPATCH (internal: no transaction of its own; the caller holds one, the order's lock and its checks).
   In order (62000 unless said):
     1. the dates: the dispatch date required, at most one day ahead (the reader's time zone), not before the order
        date; the ETA required, not before the dispatch date;
     2. the lines: only those with pieces count (none: 62009); a line not on the order; negative pieces;
     3. not above To dispatch (62012); 4. no inactive item;
     5. one dispatch at a time from the source warehouse (an application lock held to the end of the transaction);
     6. the source holds the pieces, per item over the lines (62007; the out-of-stock sales setting does not apply);
   then the On the way warehouse of the destination branch (created when missing), the TRD number by the source branch,
   the posting and its lines (each line keeps its order line's number and the item's average of the moment), the ledger
   (per line: From -q, then On the way +q, both TRF_OUT) and the order lines' Dispatched. */
CREATE   PROCEDURE inventory.usp_TransferOrder_DispatchCore
    @Id             INT,
    @Date           DATE,
    @Eta            DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- The caller's transaction holds the order's lock: posting outside one would leave the counters unguarded.
    IF @@TRANCOUNT = 0
        THROW 62010, 'A transfer dispatch is posted inside its caller''s transaction.', 1;

    SET @PostingId = NULL;
    SET @DocumentNumber = NULL;

    DECLARE @Msg NVARCHAR(400), @No NVARCHAR(30), @OrderDate DATE, @FromId INT, @ToId INT, @FromCode NVARCHAR(20),
            @FromBranchId INT, @ToBranchId INT, @TransitId INT, @TransitBranchId INT, @TypeId INT, @Lock INT,
            @Resource NVARCHAR(255), @Now DATETIME2(3) = SYSUTCDATETIME(), @MovementDate DATETIME2(3);
    DECLARE @Tomorrow DATE = DATEADD(DAY, 1, CAST(@Now AS DATE));

    DECLARE @L TABLE
    (
        OrderLineId INT           NOT NULL PRIMARY KEY,
        LineNumber  INT           NOT NULL,
        ItemId      INT           NOT NULL,
        Qty         INT           NOT NULL,
        ToDispatch  INT           NOT NULL,
        Cost        DECIMAL(18,6) NULL
    );

    SELECT @No = ISNULL(o.DocumentNumber, N'this transfer order'), @OrderDate = o.DocumentDate,
           @FromId = o.FromWarehouseId, @ToId = o.ToWarehouseId,
           @FromCode = fw.WarehouseCode, @FromBranchId = fw.BranchId, @ToBranchId = tw.BranchId
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    WHERE o.Id = @Id;
    IF @FromId IS NULL THROW 62006, 'Transfer order not found.', 1;

    -- 1. The dates (one day of tolerance ahead: the date is the reader's local one, the check is UTC)
    IF @Date IS NULL THROW 62000, 'The dispatch date is required.', 1;
    IF @Date > @Tomorrow THROW 62000, 'The dispatch date cannot be in the future.', 1;
    IF @Date < @OrderDate
    BEGIN
        SET @Msg = N'The dispatch date cannot be before the order date (' + CONVERT(NVARCHAR(10), @OrderDate, 103) + N').';
        THROW 62000, @Msg, 1;
    END
    IF @Eta IS NULL THROW 62000, 'The ETA is required.', 1;
    IF @Eta < @Date THROW 62000, 'The ETA cannot be before the dispatch date.', 1;

    -- 2. The lines: only those with pieces count; a line of another order, or pieces below 0, are refused
    IF NOT EXISTS (SELECT 1 FROM @Lines WHERE QuantityBase > 0)
        THROW 62009, 'Nothing to dispatch: type the pieces that leave.', 1;

    IF EXISTS (SELECT 1 FROM @Lines x
               WHERE x.QuantityBase <> 0
                 AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id))
    BEGIN
        SET @Msg = N'A line of the dispatch is not on ' + @No + N'.';
        THROW 62000, @Msg, 1;
    END

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the pieces dispatched cannot be negative.'
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    WHERE x.QuantityBase < 0
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    INSERT INTO @L (OrderLineId, LineNumber, ItemId, Qty, ToDispatch)
    SELECT l.Id, l.LineNumber, l.ItemId, x.QuantityBase,
           CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    WHERE x.QuantityBase > 0;

    -- 3. Not above what is left to dispatch on the line (Ordered - Dispatched - Not sent)
    SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(x.Qty AS NVARCHAR(20))
                          + N' pcs dispatched but only ' + CAST(x.ToDispatch AS NVARCHAR(20)) + N' are left to dispatch.'
    FROM @L x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.Qty > x.ToDispatch
    ORDER BY x.LineNumber;
    IF @Msg IS NOT NULL THROW 62012, @Msg, 1;

    -- 4. An item made inactive since the release
    SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
    FROM @L x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE i.IsActive = 0
    ORDER BY x.LineNumber;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 5. ONE DISPATCH AT A TIME FROM A WAREHOUSE: two orders from LKS-01 would otherwise both read the same stock and
    --    both pass step 6. Held until the caller's transaction ends.
    SET @Resource = N'inventory.TransferDispatch.' + CAST(@FromId AS NVARCHAR(10));
    EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
    IF @Lock < 0
    BEGIN
        SET @Msg = N'Another dispatch from ' + ISNULL(@FromCode, N'this warehouse') + N' is being posted. Try again in a moment.';
        THROW 62010, @Msg, 1;
    END

    -- 6. The source holds the pieces, per item over the lines (the same item may be on two lines in two units)
    SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + @FromCode + N': available '
                          + CAST(oh.Q AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT ItemId, Qty = SUM(Qty), FirstLine = MIN(LineNumber) FROM @L GROUP BY ItemId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    CROSS APPLY (SELECT Q = ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
                 WHERE m.ItemId = x.ItemId AND m.WarehouseId = @FromId) oh
    WHERE x.Qty > oh.Q
    ORDER BY x.FirstLine;
    IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

    -- 7. The goods travel in the On the way warehouse of the DESTINATION branch (created when it is missing)
    EXEC masterdata.usp_Warehouse_EnsureTransit @BranchId = @ToBranchId, @UserId = @UserId, @WarehouseId = @TransitId OUTPUT;
    SELECT @TransitBranchId = BranchId FROM masterdata.Warehouses WHERE Id = @TransitId;

    -- 8. The number, by the source branch (an inactive TRD type is refused by Blocks, Seq 83, and again here: 62008)
    SELECT @TypeId = Id FROM inventory.DocumentTypes WHERE Code = N'TRD';
    EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRD', @DocumentNumber = @DocumentNumber OUTPUT, @BranchId = @FromBranchId;

    -- 9. The posting and its lines. The cost is the item's average now, frozen for information: it moves nothing.
    UPDATE x SET Cost = i.AverageCost
    FROM @L x INNER JOIN inventory.Items i ON i.Id = x.ItemId;

    INSERT INTO inventory.TransferPostings (TransferOrderId, DocumentTypeId, Kind, DocumentNumber, PostingDate, Eta, BranchId,
                                           FromWarehouseId, ToWarehouseId, TransitWarehouseId, ReferenceNo, Notes, PostedWithId,
                                           Status, TotalQuantityBase, TotalLostBase, ValueBase, LostValueBase, PostedAtUtc, PostedBy)
    SELECT @Id, @TypeId, N'Dispatch', @DocumentNumber, @Date, @Eta, @FromBranchId,
           @FromId, @ToId, @TransitId, NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), NULL,
           2, SUM(x.Qty), 0, CAST(ROUND(SUM(CAST(x.Qty AS DECIMAL(18,6)) * ISNULL(x.Cost, 0)), 2) AS DECIMAL(18,2)), 0, @Now, @UserId
    FROM @L x;
    SET @PostingId = SCOPE_IDENTITY();

    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase)
    SELECT @PostingId, x.LineNumber, x.OrderLineId, x.ItemId, NULL, @TransitId, x.Qty, 0, NULL, NULL, 0, x.Cost, NULL
    FROM @L x
    ORDER BY x.LineNumber;

    -- 10. The ledger, per posting line: the source -q, then On the way +q (each in its warehouse's branch), dated the
    --     dispatch date at the time of posting (inventory.usp_StockDocument_Post's rule)
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, pl.ItemId, g.WarehouseId, g.BranchId, g.Sign * pl.QuantityBase, pl.UnitCostBase,
           N'Transfer', N'TRD', @PostingId, pl.Id, @DocumentNumber,
           N'TRF_OUT', NULL, 0, @UserId
    FROM inventory.TransferPostingLines pl
    CROSS APPLY (VALUES (1, @FromId, @FromBranchId, -1),
                        (2, @TransitId, @TransitBranchId, 1)) g (Leg, WarehouseId, BranchId, Sign)
    WHERE pl.PostingId = @PostingId
    ORDER BY pl.LineNumber, g.Leg;

    -- 11. The order lines' Dispatched (posted, not reversed postings only)
    UPDATE l SET DispatchedBase = l.DispatchedBase + x.Qty
    FROM inventory.TransferOrderLines l
    INNER JOIN @L x ON x.OrderLineId = l.Id;
END

GO

