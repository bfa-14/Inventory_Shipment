/* 13.23 REVERSE ONE WHOLE DISPATCH OR RECEIPT, in place (FB decision 8, T23-T24). The posting's order is locked and its
   RowVersion checked (@RowVersion is the ORDER's); then the order's rule (Blocks, ReverseDispatch / ReverseReceipt) and
   the posting's (fn_TransferPosting_ReverseBlock: not reversed yet; a dispatch after the receipts of its goods; a receipt
   while the destination still holds what it brought) - a reverse that can never go through says so before it asks for a
   reason (script 83) - then the reason and the date (today by default, at most one day ahead, not before the posting).
   Every ledger row of the posting gets its opposite (every column copied, ExpiryDate included; the pieces negated;
   IsReversal 1; CreatedBy the acting user), dated the reversal date at the time it is done but never before the rows it
   undoes + 1 second - for a dispatch, never before any row of a receipt of its lines in its On the way warehouse either
   (a receipt reversed later than the dispatch's reversal date would otherwise leave the On the way warehouse below 0 in
   between). A dispatch takes its pieces off the order lines' Dispatched (and adds them to Not sent on a closed order:
   it stays closed); a receipt takes its pieces off its dispatch lines' Settled and the order lines' Received and Lost
   (its goods are back On the way, its write-off undone). The posting is marked Reversed with the date, the reason and
   who. The cost replay leaves a reversed posting out with its reversal; no partial reversal.
   A RECEIPT THAT WROTE PIECES OFF changes the company's stock when it is reversed (the lost pieces come back at the
   average frozen on the loss, which may have moved since): its items' costs are REPLAYED (inventory.usp_Item_RebuildCosts),
   as every cancel that writes reversal rows (M4, script 89), under the goods receipt matching lock taken first (89's
   order: the matcher, then the document), giving way in a deadlock (DEADLOCK_PRIORITY LOW: the API runs it again). A
   dispatch, or a receipt without a loss, leaves the company's stock as it was: no replay. A receipt's reversal takes
   pieces out of To: it holds the dispatch lock of To (inventory.TransferDispatch.{To}) before it checks To's stock,
   so a dispatch from To cannot pass its stock check on the same pieces at the same time. */
CREATE   PROCEDURE inventory.usp_TransferPosting_Reverse
    @PostingId  INT,
    @RowVersion BINARY(8)     = NULL,     -- the ORDER's
    @Reason     NVARCHAR(300) = NULL,
    @Date       DATE          = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DEADLOCK_PRIORITY LOW;      -- the replay of a reversed loss reads the item's ledger: the reverse gives way, the API runs it again

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @OrderId INT, @Status TINYINT, @Kind NVARCHAR(10), @TypeCode NVARCHAR(20),
            @Number NVARCHAR(30), @PostingDate DATE, @NotSentAt DATETIME2(3),
            @Now DATETIME2(3) = SYSUTCDATETIME(), @ReversalAt DATETIME2(3), @Latest DATETIME2(3), @LatestReceipts DATETIME2(3),
            @ToId INT, @Resource NVARCHAR(255), @Lock INT, @ItemId INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- a receipt that wrote pieces off: the matching lock first, for the replay below (89's lock order)
        IF EXISTS (SELECT 1 FROM inventory.TransferPostings
                   WHERE Id = @PostingId AND Kind = N'Receipt' AND Status = 2 AND TotalLostBase > 0)
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        SELECT @OrderId = TransferOrderId FROM inventory.TransferPostings WHERE Id = @PostingId;
        IF @OrderId IS NULL
        BEGIN
            SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
            FROM inventory.fn_TransferPosting_ReverseBlock(@PostingId) q
            WHERE q.Message IS NOT NULL
            ORDER BY q.Seq;
            SELECT @ErrNo = ISNULL(@ErrNo, 62006), @Msg = ISNULL(@Msg, N'Dispatch or receipt not found.');
            THROW @ErrNo, @Msg, 1;
        END

        SELECT @Status = Status, @NotSentAt = NotSentAtUtc
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @OrderId;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @OrderId AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT @Kind = Kind, @Number = DocumentNumber, @PostingDate = PostingDate, @ToId = ToWarehouseId,
               @TypeCode = CASE Kind WHEN N'Dispatch' THEN N'TRD' ELSE N'TRR' END
        FROM inventory.TransferPostings WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PostingId;

        -- a receipt takes its pieces back out of To: one stock check at a time on To, with the dispatches from To
        -- (inventory.usp_TransferOrder_DispatchCore step 5; the same order: the order header, then the warehouse)
        IF @Kind = N'Receipt'
        BEGIN
            SET @Resource = N'inventory.TransferDispatch.' + CAST(@ToId AS NVARCHAR(10));
            EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
            IF @Lock < 0
            BEGIN
                SELECT @Msg = N'Another dispatch from ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToId), N'this warehouse')
                              + N' is being posted. Try again in a moment.';
                THROW 62010, @Msg, 1;
            END
        END

        -- the order's rule first, then the posting's own
        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@OrderId, @UserId) b
        WHERE b.Action = CASE @Kind WHEN N'Dispatch' THEN N'ReverseDispatch' ELSE N'ReverseReceipt' END AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferPosting_ReverseBlock(@PostingId) q
        WHERE q.Message IS NOT NULL
        ORDER BY q.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to reverse it.', 1;

        IF @Date IS NULL SET @Date = CAST(@Now AS DATE);
        IF @Date > DATEADD(DAY, 1, CAST(@Now AS DATE)) THROW 62000, 'The reversal date cannot be in the future.', 1;
        IF @Date < @PostingDate
        BEGIN
            SET @Msg = N'The reversal cannot be dated before ' + @Number + N' (' + CONVERT(NVARCHAR(10), @PostingDate, 103) + N').';
            THROW 62000, @Msg, 1;
        END

        -- its own rows only; a posting without any is refused rather than marked reversed (inventory.usp_StockDocument_Cancel, 89)
        IF NOT EXISTS (SELECT 1 FROM inventory.StockMovements m
                       WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId AND m.IsReversal = 0)
            THROW 62010, 'This dispatch or receipt has no stock movements of its own to reverse. Ask the administrator to check the stock ledger.', 1;

        -- the date of the reversal rows: see the header
        SET @ReversalAt = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));
        SELECT @Latest = MAX(m.MovementDate)
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId;
        IF @Kind = N'Dispatch'
            SELECT @LatestReceipts = MAX(m.MovementDate)
            FROM inventory.TransferPostingLines dl
            INNER JOIN inventory.TransferPostingLines rl ON rl.DispatchLineId = dl.Id
            INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRR'
                                                 AND m.DocumentId = rl.PostingId AND m.DocumentLineId = rl.Id
                                                 AND m.WarehouseId = dl.TransitWarehouseId
            WHERE dl.PostingId = @PostingId;
        IF @LatestReceipts > @Latest SET @Latest = @LatestReceipts;
        IF @Latest IS NOT NULL AND @ReversalAt < DATEADD(SECOND, 1, @Latest)
            SET @ReversalAt = DATEADD(SECOND, 1, @Latest);

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                              ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT @ReversalAt, m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber,
               m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId AND m.IsReversal = 0
        ORDER BY m.Id;

        IF @Kind = N'Dispatch'
        BEGIN
            -- its pieces leave the order's Dispatched; on a closed order they become Not sent (it stays closed)
            UPDATE l SET DispatchedBase = l.DispatchedBase - x.Qty,
                         NotSentBase    = l.NotSentBase + CASE WHEN @NotSentAt IS NOT NULL THEN x.Qty ELSE 0 END
            FROM inventory.TransferOrderLines l
            INNER JOIN (SELECT TransferOrderLineId, Qty = SUM(QuantityBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY TransferOrderLineId) x ON x.TransferOrderLineId = l.Id;
        END
        ELSE
        BEGIN
            -- its goods are back On the way, its write-off undone
            UPDATE dl SET SettledBase = dl.SettledBase - x.Qty
            FROM inventory.TransferPostingLines dl
            INNER JOIN (SELECT DispatchLineId, Qty = SUM(QuantityBase + LostBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY DispatchLineId) x ON x.DispatchLineId = dl.Id;

            UPDATE l SET ReceivedBase = l.ReceivedBase - x.Received, LostBase = l.LostBase - x.Lost
            FROM inventory.TransferOrderLines l
            INNER JOIN (SELECT TransferOrderLineId, Received = SUM(QuantityBase), Lost = SUM(LostBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY TransferOrderLineId) x ON x.TransferOrderLineId = l.Id;
        END

        UPDATE inventory.TransferPostings
        SET Status = 3, ReversedAtUtc = @Now, ReversedBy = @UserId, ReverseDate = @Date, ReverseReason = @Reason
        WHERE Id = @PostingId;

        -- a receipt's write-off undone: the company's stock changed, so its items' costs are replayed (see the header)
        IF @Kind = N'Receipt'
        BEGIN
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT ItemId FROM inventory.TransferPostingLines WHERE PostingId = @PostingId AND LostBase > 0;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @OrderId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        VALUES (@OrderId, @PostingId, N'Reversed',
                LEFT(@Number + N' reversed on ' + CONVERT(NVARCHAR(10), @Date, 103) + N': ' + @Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

