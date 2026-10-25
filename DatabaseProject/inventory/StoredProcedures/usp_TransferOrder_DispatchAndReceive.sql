/* 13.20 DISPATCH AND RECEIVE (Blocks, DispatchAndReceive: Dispatch's rules and TRR active; FB decision 17) - one date,
   one transaction: the dispatch core with ETA = the date, then the receipt core with one row per new dispatch line
   (received = all of it, nothing lost), the same date, PostedWithId = the dispatch. Any refusal of either rolls both
   back, numbers included (the number sequences are written in this transaction). Earlier dispatches on the way are
   untouched. Dispatch's parameters; @Eta is not read. Result set: DispatchPostingId, DispatchNumber, ReceiptPostingId,
   ReceiptNumber; @PostingId / @DocumentNumber = the dispatch's. */
CREATE   PROCEDURE inventory.usp_TransferOrder_DispatchAndReceive
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @Eta            DATE           = NULL,      -- not read: the goods arrive on @Date
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

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(),
            @ReceiptId INT, @ReceiptNumber NVARCHAR(30), @Pcs INT;
    DECLARE @Receipt inventory.tvp_TransferReceiptLine;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'DispatchAndReceive' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_DispatchCore @Id = @Id, @Date = @Date, @Eta = @Date, @ReferenceNo = @ReferenceNo,
             @Notes = @Notes, @Lines = @Lines, @UserId = @UserId,
             @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT;

        -- the receipt takes exactly what was just dispatched
        INSERT INTO @Receipt (DispatchLineId, ReceivedBase, NothingMoreWillArrive, LossReasonCode, LossNote)
        SELECT pl.Id, pl.QuantityBase, 0, NULL, NULL
        FROM inventory.TransferPostingLines pl
        WHERE pl.PostingId = @PostingId;

        EXEC inventory.usp_TransferOrder_ReceiveCore @Id = @Id, @Date = @Date, @ReferenceNo = @ReferenceNo, @Notes = @Notes,
             @Lines = @Receipt, @UserId = @UserId, @PostingId = @ReceiptId OUTPUT, @DocumentNumber = @ReceiptNumber OUTPUT,
             @PostedWithId = @PostingId;

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        SELECT @Pcs = TotalQuantityBase FROM inventory.TransferPostings WHERE Id = @PostingId;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, @PostingId, N'DispatchedAndReceived',
               LEFT(@DocumentNumber + N' and ' + @ReceiptNumber + N': ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs from '
                    + fw.WarehouseCode + N' to ' + tw.WarehouseCode + N' on ' + CONVERT(NVARCHAR(10), @Date, 103) + N'.', 500),
               @UserId
        FROM inventory.TransferOrders o
        INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
        INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
        WHERE o.Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT DispatchPostingId = @PostingId, DispatchNumber = @DocumentNumber,
           ReceiptPostingId = @ReceiptId, ReceiptNumber = @ReceiptNumber;
END

GO

