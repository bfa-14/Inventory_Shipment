/* 13.17 DISPATCH (Blocks, Dispatch: a released order, not closed, something to dispatch, TRD active, the warehouses, some
   stock at From): the core above, the order's header stamp and the audit "{TRD}: {n} line(s), {pcs} pcs, ETA {date}.".
   Result set: PostingId, DocumentNumber (the API answers "{TRD} posted: {q} pcs left {From}."). */
CREATE   PROCEDURE inventory.usp_TransferOrder_Dispatch
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
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

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Dispatch' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_DispatchCore @Id = @Id, @Date = @Date, @Eta = @Eta, @ReferenceNo = @ReferenceNo,
             @Notes = @Notes, @Lines = @Lines, @UserId = @UserId,
             @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT;

        -- The order's RowVersion moves with its postings: a page opened before the dispatch must reload before it acts.
        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, p.Id, N'Dispatched',
               LEFT(p.DocumentNumber + N': ' + CAST(n.Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(p.TotalQuantityBase AS NVARCHAR(20))
                    + N' pcs, ETA ' + CONVERT(NVARCHAR(10), p.Eta, 103) + N'.', 500),
               @UserId
        FROM inventory.TransferPostings p
        CROSS APPLY (SELECT Lines = COUNT(*) FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id) n
        WHERE p.Id = @PostingId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PostingId = @PostingId, DocumentNumber = @DocumentNumber;
END

GO

