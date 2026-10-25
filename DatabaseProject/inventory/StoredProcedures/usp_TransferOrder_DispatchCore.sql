/* ================================================================== 8. The transfer procedures (5.3.7)

   Each re-created (93) from its CURRENT body (script 90's for the cores, the public dispatch / receive procedures and
   Reverse; 91's for Get; 92's for Search) plus the change its "Re-created (93)" line names, the changed lines marked
   (93); every 90 / 91 / 92 sentence, number, lock and check stays; every ledger INSERT stamps CreatedBy = @UserId and
   has no OUTPUT (W16). */

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
-- Re-created (93) from the body of script 90: + @Tracking; the batch, serial and expiry rules before the source lock
-- (step 4b), one lock per serial item after it (5b), the serial on the way after the stock check (6b), the posting
-- lines' TrackingKind and their rows (9b), the ledger per posting line and expiry date (10).
CREATE   PROCEDURE inventory.usp_TransferOrder_DispatchCore
    @Id             INT,
    @Date           DATE,
    @Eta            DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @Tracking       inventory.tvp_TransferDispatchTracking READONLY        -- (93) the rows of the tracked lines; omitted = none
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
    DECLARE @ErrNo INT, @SerialItemId INT, @SerialItemCode NVARCHAR(30), @Tracked BIT = 0;     -- (93)

    DECLARE @L TABLE
    (
        OrderLineId INT           NOT NULL PRIMARY KEY,
        LineNumber  INT           NOT NULL,
        ItemId      INT           NOT NULL,
        Qty         INT           NOT NULL,
        ToDispatch  INT           NOT NULL,
        Cost        DECIMAL(18,6) NULL,
        K           TINYINT       NULL          -- (93) the item's kind when the line is read: 2 Serial, 1 Batch, 3 Expiry
    );

    -- (93) 0. The batch and serial numbers as they are kept (fn_TrackingNo_Normalize), once per row
    DECLARE @T inventory.tvp_TransferDispatchTracking;
    INSERT INTO @T (TransferOrderLineId, RowNumber, BatchNo, SerialNo, ExpiryDate, QuantityBase)
    SELECT TransferOrderLineId, RowNumber,
           CASE WHEN BatchNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(BatchNo) END,      -- a call only when there is a number
           CASE WHEN SerialNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(SerialNo) END,
           ExpiryDate, QuantityBase
    FROM @Tracking;

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

    INSERT INTO @L (OrderLineId, LineNumber, ItemId, Qty, ToDispatch, K)                                         -- (93)
    SELECT l.Id, l.LineNumber, l.ItemId, x.QuantityBase,
           CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END,
           CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END      -- (93)
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    INNER JOIN inventory.Items i              ON i.Id = l.ItemId                                                   -- (93)
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

    -- (93) 4b. THE BATCH, SERIAL AND EXPIRY ROWS (fn_TransferDispatch_TrackingProblems, the dialog's own rules): the
    --      format, count and duplicate errors BEFORE the source lock (B17), so a slow check never blocks the warehouse.
    --      An untracked dispatch (no row, no line of a tracked item) runs script 90's checks only.
    IF EXISTS (SELECT 1 FROM @T) OR EXISTS (SELECT 1 FROM @L WHERE K IS NOT NULL)
    BEGIN
        SET @Tracked = 1;
        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferDispatch_TrackingProblems(@Id, @Lines, @T, NULL) q
        WHERE q.Severity = N'Error' AND q.Seq < 90
        ORDER BY q.Seq, q.LineNumber, q.RowNumber;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
    END

    -- 5. ONE DISPATCH AT A TIME FROM A WAREHOUSE: two orders from LKS-01 would otherwise both read the same stock and
    --    both pass step 6. Held until the caller's transaction ends.
    SET @Resource = N'inventory.TransferDispatch.' + CAST(@FromId AS NVARCHAR(10));
    EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
    IF @Lock < 0
    BEGIN
        SET @Msg = N'Another dispatch from ' + ISNULL(@FromCode, N'this warehouse') + N' is being posted. Try again in a moment.';
        THROW 62010, @Msg, 1;
    END

    -- (93) 5b. ONE DISPATCH OF AN ITEM'S SERIALS AT A TIME, from any warehouse (B5): two dispatches of one serial from two
    --      warehouses would otherwise both pass step 6b. One lock per serial item, in ItemId order, so two dispatches
    --      never wait for each other in a circle. Held until the caller's transaction ends.
    SET @SerialItemId = 0;
    WHILE 1 = 1
    BEGIN
        SET @SerialItemCode = NULL;
        SELECT TOP (1) @SerialItemId = x.ItemId, @SerialItemCode = i.ItemCode
        FROM @L x
        INNER JOIN inventory.Items i ON i.Id = x.ItemId
        WHERE x.K = 2 AND x.ItemId > @SerialItemId
        ORDER BY x.ItemId;
        IF @SerialItemCode IS NULL BREAK;

        SET @Resource = N'inventory.TransferSerial.' + CAST(@SerialItemId AS NVARCHAR(10));
        EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
        IF @Lock < 0
        BEGIN
            SET @Msg = N'Another dispatch of ' + @SerialItemCode + N' serial numbers is being posted. Try again in a moment.';
            THROW 62010, @Msg, 1;
        END
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

    -- (93) 6b. NEVER ON THE WAY TWICE (62017), read under the serial locks of 5b
    IF EXISTS (SELECT 1 FROM @T WHERE SerialNo IS NOT NULL)
    BEGIN
        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferDispatch_TrackingProblems(@Id, @Lines, @T, NULL) q
        WHERE q.Seq = 90
        ORDER BY q.LineNumber, q.RowNumber;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
    END

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

    -- (93) a line that carries rows keeps the kind they were checked against (B3); any other line NULL, as in script 90
    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase,
                                                TrackingKind)
    SELECT @PostingId, x.LineNumber, x.OrderLineId, x.ItemId, NULL, @TransitId, x.Qty, 0, NULL, NULL, 0, x.Cost, NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @T t WHERE t.TransferOrderLineId = x.OrderLineId) THEN x.K END                -- (93)
    FROM @L x
    ORDER BY x.LineNumber;

    -- (93) 9b. The rows: one per serial no., per batch or per expiry group, in the order typed (B7: never on the ledger)
    IF @Tracked = 1
        INSERT INTO inventory.TransferPostingTracking (PostingLineId, PostingId, ItemId, RowNumber, Kind, BatchNo, SerialNo, ExpiryDate,
                                                       QuantityBase, LostBase, SettledBase, DispatchTrackingId)
        SELECT pl.Id, @PostingId, pl.ItemId, ROW_NUMBER() OVER (PARTITION BY t.TransferOrderLineId ORDER BY t.RowNumber), pl.TrackingKind,
               CASE WHEN pl.TrackingKind = 1 THEN t.BatchNo END, CASE WHEN pl.TrackingKind = 2 THEN t.SerialNo END, t.ExpiryDate,
               t.QuantityBase, 0, 0, NULL
        FROM @T t
        INNER JOIN inventory.TransferPostingLines pl ON pl.PostingId = @PostingId AND pl.TransferOrderLineId = t.TransferOrderLineId
        WHERE pl.TrackingKind IS NOT NULL;

    -- 10. The ledger, per posting line: the source -q, then On the way +q (each in its warehouse's branch), dated the
    --     dispatch date at the time of posting (inventory.usp_StockDocument_Post's rule). (93) Per posting line AND
    --     EXPIRY DATE (B7): a tracked line one pair per distinct ExpiryDate of its rows (NULL a group) with the group's
    --     pcs; an untracked line one pair of its pcs without expiry - script 90's rows exactly.
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, pl.ItemId, g.WarehouseId, g.BranchId, g.Sign * e.Qty, pl.UnitCostBase,                 -- (93)
           N'Transfer', N'TRD', @PostingId, pl.Id, @DocumentNumber,
           N'TRF_OUT', e.ExpiryDate, 0, @UserId                                                                  -- (93)
    FROM inventory.TransferPostingLines pl
    CROSS APPLY (SELECT t.ExpiryDate, Qty = SUM(t.QuantityBase)                                                    -- (93)
                 FROM inventory.TransferPostingTracking t
                 WHERE t.PostingLineId = pl.Id AND pl.TrackingKind IS NOT NULL
                 GROUP BY t.ExpiryDate
                 UNION ALL
                 SELECT CAST(NULL AS DATE), pl.QuantityBase
                 WHERE pl.TrackingKind IS NULL) e
    CROSS APPLY (VALUES (1, @FromId, @FromBranchId, -1),
                        (2, @TransitId, @TransitBranchId, 1)) g (Leg, WarehouseId, BranchId, Sign)
    WHERE pl.PostingId = @PostingId
    ORDER BY pl.LineNumber, CASE WHEN e.ExpiryDate IS NULL THEN 0 ELSE 1 END, e.ExpiryDate, g.Leg;               -- (93)

    -- 11. The order lines' Dispatched (posted, not reversed postings only)
    UPDATE l SET DispatchedBase = l.DispatchedBase + x.Qty
    FROM inventory.TransferOrderLines l
    INNER JOIN @L x ON x.OrderLineId = l.Id;
END

GO

