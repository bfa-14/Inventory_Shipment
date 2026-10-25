/* 13.18 POST A TRANSFER RECEIPT (internal: no transaction of its own; the caller holds one, the order's lock and its
   checks). Each row receives one dispatch line. In order (62000 unless said):
     1. the dispatch line is on a POSTED dispatch of this order; 2. received not below 0;
     3. received not above what is on the way on that dispatch line (62012);
     4. "Nothing more will arrive": the rest (on the way - received) is LOST and needs a reason (Damaged, Missing,
        Wrongly counted at dispatch, Other with a note);
     5. rows that receive and lose nothing are ignored; none left: 62009;
     6. the receipt date required, at most one day ahead, not before any dispatch it receives;
     7. the destination still fit (Blocks Receive, Seq 92: its sentences in one place);
     8. a safety net: the On the way warehouse holds what is received and written off (62007);
   then the TRR number by the destination branch, the posting and its lines (1..n, dispatch then line; the dispatch
   line's frozen cost; the item's average now on a line with a loss), the ledger (per line, the legs with pieces: On the
   way -received and To +received, TRF_IN, at the dispatch's cost; On the way -lost, TRF_LOSS, at the average - the only
   leg of a transfer that changes the company's stock), the dispatch lines' Settled and the order lines' Received and
   Lost. @PostedWithId: the dispatch of a "Dispatch and receive".
   THE MOVEMENT DATE is the receipt date at the time of posting, but never before the latest ledger row in the On the
   way warehouse of the dispatch lines it receives (their dispatch rows, their earlier receipts and every reversal of
   those) + 1 second: a receipt typed the next morning for yesterday, after an earlier receipt was reversed today, would
   otherwise take the pieces out of On the way before that reversal put them back, and the warehouse's running balance
   would dip below 0. */
CREATE   PROCEDURE inventory.usp_TransferOrder_ReceiveCore
    @Id             INT,
    @Date           DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferReceiptLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @PostedWithId   INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT = 0
        THROW 62010, 'A transfer receipt is posted inside its caller''s transaction.', 1;

    SET @PostingId = NULL;
    SET @DocumentNumber = NULL;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @No NVARCHAR(30), @FromId INT, @ToId INT, @ToBranchId INT, @TypeId INT,
            @Now DATETIME2(3) = SYSUTCDATETIME(), @MovementDate DATETIME2(3), @Latest DATETIME2(3);
    DECLARE @Tomorrow DATE = DATEADD(DAY, 1, CAST(@Now AS DATE));

    DECLARE @R TABLE
    (
        DispatchLineId     INT           NOT NULL PRIMARY KEY,
        DispatchId         INT           NOT NULL,
        DispatchNumber     NVARCHAR(30)  NOT NULL,
        DispatchDate       DATE          NOT NULL,
        DispatchPostedAt   DATETIME2(3)  NOT NULL,
        DispatchLineNumber INT           NOT NULL,
        OrderLineId        INT           NOT NULL,
        ItemId             INT           NOT NULL,
        TransitId          INT           NOT NULL,
        UnitCost           DECIMAL(18,6) NULL,
        OnTheWay           INT           NOT NULL,
        Received           INT           NOT NULL,
        NothingMore        BIT           NOT NULL,
        Lost               INT           NOT NULL DEFAULT (0),
        ReasonCode         NVARCHAR(20)  NULL,
        Note               NVARCHAR(300) NULL,
        LossCost           DECIMAL(18,6) NULL,
        Seq                INT           NULL
    );

    SELECT @No = ISNULL(o.DocumentNumber, N'this transfer order'), @FromId = o.FromWarehouseId, @ToId = o.ToWarehouseId,
           @ToBranchId = tw.BranchId
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    WHERE o.Id = @Id;
    IF @ToId IS NULL THROW 62006, 'Transfer order not found.', 1;

    -- 1. Each row receives a line of a dispatch of this order that is still posted
    IF EXISTS (SELECT 1 FROM @Lines x
               WHERE NOT EXISTS (SELECT 1
                                 FROM inventory.TransferPostingLines dl
                                 INNER JOIN inventory.TransferPostings dp ON dp.Id = dl.PostingId
                                 WHERE dl.Id = x.DispatchLineId AND dl.DispatchLineId IS NULL
                                   AND dp.TransferOrderId = @Id AND dp.Kind = N'Dispatch' AND dp.Status = 2))
    BEGIN
        SET @Msg = N'A line of the receipt is not on a dispatch of ' + @No + N' that is still posted.';
        THROW 62000, @Msg, 1;
    END

    INSERT INTO @R (DispatchLineId, DispatchId, DispatchNumber, DispatchDate, DispatchPostedAt, DispatchLineNumber, OrderLineId,
                    ItemId, TransitId, UnitCost, OnTheWay, Received, NothingMore, ReasonCode, Note)
    SELECT dl.Id, dp.Id, dp.DocumentNumber, dp.PostingDate, dp.PostedAtUtc, dl.LineNumber, dl.TransferOrderLineId,
           dl.ItemId, dl.TransitWarehouseId, dl.UnitCostBase, dl.QuantityBase - dl.SettledBase, x.ReceivedBase,
           ISNULL(x.NothingMoreWillArrive, 0),
           NULLIF(UPPER(LTRIM(RTRIM(x.LossReasonCode))), N''), NULLIF(LTRIM(RTRIM(x.LossNote)), N'')
    FROM @Lines x
    INNER JOIN inventory.TransferPostingLines dl ON dl.Id = x.DispatchLineId
    INNER JOIN inventory.TransferPostings dp     ON dp.Id = dl.PostingId;

    -- dispatch then line: the receipt's line numbers, and the order every "first failing" below is looked for in
    UPDATE r SET Seq = s.Seq
    FROM @R r
    INNER JOIN (SELECT DispatchLineId, Seq = ROW_NUMBER() OVER (ORDER BY DispatchPostedAt, DispatchId, DispatchLineNumber) FROM @R) s
            ON s.DispatchLineId = r.DispatchLineId;

    -- 2. Not below 0
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                          + N'): the pieces received cannot be negative.'
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Received < 0
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 3. Not above what is on the way on the dispatch line
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CAST(r.Received AS NVARCHAR(20)) + N' pcs received but only ' + CAST(r.OnTheWay AS NVARCHAR(20)) + N' are on the way.'
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Received > r.OnTheWay
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62012, @Msg, 1;

    -- 4. "Nothing more will arrive": the rest is lost and says why. A reason sent with nothing lost is not kept.
    UPDATE @R SET Lost = CASE WHEN NothingMore = 1 THEN OnTheWay - Received ELSE 0 END;
    UPDATE @R SET ReasonCode = NULL, Note = NULL WHERE Lost = 0;

    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CASE WHEN r.ReasonCode IS NULL THEN N'choose why the rest will not arrive.'
                                 WHEN r.ReasonCode NOT IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER') THEN N'unknown reason.'
                                 ELSE N'say what happened in the note (reason Other).' END
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Lost > 0
      AND (r.ReasonCode IS NULL OR r.ReasonCode NOT IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER')
           OR (r.ReasonCode = N'OTHER' AND r.Note IS NULL))
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 5. Rows that receive and lose nothing are ignored
    DELETE FROM @R WHERE Received = 0 AND Lost = 0;
    IF NOT EXISTS (SELECT 1 FROM @R)
        THROW 62009, 'Nothing to receive: type the pieces that arrived, or tick Nothing more will arrive.', 1;

    UPDATE r SET Seq = s.Seq
    FROM @R r
    INNER JOIN (SELECT DispatchLineId, Seq = ROW_NUMBER() OVER (ORDER BY DispatchPostedAt, DispatchId, DispatchLineNumber) FROM @R) s
            ON s.DispatchLineId = r.DispatchLineId;

    -- 6. The date: not before the latest dispatch it receives
    IF @Date IS NULL THROW 62000, 'The receipt date is required.', 1;
    IF @Date > @Tomorrow THROW 62000, 'The receipt date cannot be in the future.', 1;
    SELECT TOP (1) @Msg = N'TRR cannot be dated before ' + r.DispatchNumber + N' left on ' + CONVERT(NVARCHAR(10), r.DispatchDate, 103) + N'.'
    FROM @R r
    WHERE r.DispatchDate > @Date
    ORDER BY r.DispatchDate DESC, r.DispatchPostedAt DESC, r.DispatchId DESC;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 7. The destination: rules 3-5 of fn_TransferOrder_WarehouseProblem for To alone, inactive in its own words
    --    (Blocks, Receive, Seq 92: the one place of these sentences)
    SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
    FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
    WHERE b.Action = N'Receive' AND b.Seq = 92 AND b.Message IS NOT NULL
    ORDER BY b.Seq;
    IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

    -- 8. A safety net: the On the way warehouse holds what this receipt takes out of it
    SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                          + CAST(oh.Q AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT ItemId, TransitId, Qty = SUM(Received + Lost), FirstSeq = MIN(Seq) FROM @R GROUP BY ItemId, TransitId) x
    INNER JOIN inventory.Items i       ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.TransitId
    CROSS APPLY (SELECT Q = ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
                 WHERE m.ItemId = x.ItemId AND m.WarehouseId = x.TransitId) oh
    WHERE x.Qty > oh.Q
    ORDER BY x.FirstSeq;
    IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

    -- 9. The number, by the destination branch (an inactive TRR type: Blocks Seq 84, and again here: 62008)
    SELECT @TypeId = Id FROM inventory.DocumentTypes WHERE Code = N'TRR';
    EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRR', @DocumentNumber = @DocumentNumber OUTPUT, @BranchId = @ToBranchId;

    -- 10. The posting and its lines: received at the dispatch's frozen cost, lost at the average now
    UPDATE r SET LossCost = i.AverageCost
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Lost > 0;

    INSERT INTO inventory.TransferPostings (TransferOrderId, DocumentTypeId, Kind, DocumentNumber, PostingDate, Eta, BranchId,
                                           FromWarehouseId, ToWarehouseId, TransitWarehouseId, ReferenceNo, Notes, PostedWithId,
                                           Status, TotalQuantityBase, TotalLostBase, ValueBase, LostValueBase, PostedAtUtc, PostedBy)
    SELECT @Id, @TypeId, N'Receipt', @DocumentNumber, @Date, NULL, @ToBranchId,
           @FromId, @ToId, NULL, NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), @PostedWithId,
           2, SUM(r.Received), SUM(r.Lost),
           CAST(ROUND(SUM(CAST(r.Received AS DECIMAL(18,6)) * ISNULL(r.UnitCost, 0)), 2) AS DECIMAL(18,2)),
           CAST(ROUND(SUM(CAST(r.Lost AS DECIMAL(18,6)) * ISNULL(r.LossCost, 0)), 2) AS DECIMAL(18,2)),
           @Now, @UserId
    FROM @R r;
    SET @PostingId = SCOPE_IDENTITY();

    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase)
    SELECT @PostingId, r.Seq, r.OrderLineId, r.ItemId, r.DispatchLineId, r.TransitId,
           r.Received, r.Lost, r.ReasonCode, r.Note, 0, r.UnitCost, r.LossCost
    FROM @R r
    ORDER BY r.Seq;

    -- 11. The ledger. The movement date: see the header (never before what it receives, + 1 second).
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    ;WITH k AS
    (
        SELECT DocumentId = r.DispatchId, DocumentLineId = r.DispatchLineId, TypeCode = N'TRD', WarehouseId = r.TransitId
        FROM @R r
        UNION ALL
        SELECT rl.PostingId, rl.Id, N'TRR', r.TransitId
        FROM @R r
        INNER JOIN inventory.TransferPostingLines rl ON rl.DispatchLineId = r.DispatchLineId
        WHERE rl.PostingId <> @PostingId
    )
    SELECT @Latest = MAX(m.MovementDate)
    FROM k
    INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Transfer' AND m.DocumentId = k.DocumentId
                                         AND m.DocumentTypeCode = k.TypeCode AND m.DocumentLineId = k.DocumentLineId
                                         AND m.WarehouseId = k.WarehouseId;
    IF @Latest IS NOT NULL AND @MovementDate < DATEADD(SECOND, 1, @Latest)
        SET @MovementDate = DATEADD(SECOND, 1, @Latest);

    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, rl.ItemId, g.WarehouseId, w.BranchId, g.Qty, g.Cost,
           N'Transfer', N'TRR', @PostingId, rl.Id, @DocumentNumber,
           g.Reason, NULL, 0, @UserId
    FROM inventory.TransferPostingLines rl
    CROSS APPLY (VALUES (1, rl.TransitWarehouseId, -rl.QuantityBase, rl.UnitCostBase,     N'TRF_IN'),
                        (2, @ToId,                  rl.QuantityBase, rl.UnitCostBase,     N'TRF_IN'),
                        (3, rl.TransitWarehouseId, -rl.LostBase,     rl.LossUnitCostBase, N'TRF_LOSS')) g (Leg, WarehouseId, Qty, Cost, Reason)
    INNER JOIN masterdata.Warehouses w ON w.Id = g.WarehouseId
    WHERE rl.PostingId = @PostingId AND g.Qty <> 0
    ORDER BY rl.LineNumber, g.Leg;

    -- 12. The dispatch lines' Settled; the order lines' Received and Lost (one order line may be received from two
    --     dispatches in one receipt)
    UPDATE dl SET SettledBase = dl.SettledBase + r.Received + r.Lost
    FROM inventory.TransferPostingLines dl
    INNER JOIN @R r ON r.DispatchLineId = dl.Id;

    UPDATE l SET ReceivedBase = l.ReceivedBase + x.Received, LostBase = l.LostBase + x.Lost
    FROM inventory.TransferOrderLines l
    INNER JOIN (SELECT OrderLineId, Received = SUM(Received), Lost = SUM(Lost) FROM @R GROUP BY OrderLineId) x ON x.OrderLineId = l.Id;
END

GO

