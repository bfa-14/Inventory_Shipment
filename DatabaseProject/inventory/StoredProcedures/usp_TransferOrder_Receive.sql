/* 13.19 RECEIVE (Blocks, Receive: a released order with goods on the way, TRR active, the destination fit): the core
   above, the order's header stamp and the audit "{TRR}: {r} pcs received from {TRD list}; {l} pc(s) written off
   ({reasons})." (the second part only with a loss). Result set: PostingId, DocumentNumber, ReceivedBase, LostBase. */
CREATE   PROCEDURE inventory.usp_TransferOrder_Receive
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferReceiptLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(),
            @Received INT, @Lost INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Receive' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_ReceiveCore @Id = @Id, @Date = @Date, @ReferenceNo = @ReferenceNo, @Notes = @Notes,
             @Lines = @Lines, @UserId = @UserId, @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT,
             @PostedWithId = NULL;

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        SELECT @Received = TotalQuantityBase, @Lost = TotalLostBase FROM inventory.TransferPostings WHERE Id = @PostingId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, @PostingId, N'Received',
               LEFT(@DocumentNumber + N': ' + CAST(@Received AS NVARCHAR(20)) + N' pcs received from ' + ISNULL(d.List, N'')
                    + CASE WHEN d.N > 3 THEN N' and ' + CAST(d.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                    + CASE WHEN @Lost > 0 THEN N'; ' + CAST(@Lost AS NVARCHAR(20)) + N' pc(s) written off (' + ISNULL(rs.Names, N'') + N')' ELSE N'' END
                    + N'.', 500),
               @UserId
        FROM (SELECT N = COUNT(*),
                     List = (SELECT STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc, t.Id)
                             FROM (SELECT TOP (3) dp.Id, dp.DocumentNumber, dp.PostedAtUtc
                                   FROM inventory.TransferPostings dp
                                   WHERE EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                                                 INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                                                 WHERE rl.PostingId = @PostingId AND dl.PostingId = dp.Id)
                                   ORDER BY dp.PostedAtUtc, dp.Id) t)
              FROM inventory.TransferPostings dp
              WHERE EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                            INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                            WHERE rl.PostingId = @PostingId AND dl.PostingId = dp.Id)) d
        CROSS APPLY (SELECT Names = STRING_AGG(n.Name, N', ') WITHIN GROUP (ORDER BY n.Sort)
                     FROM (SELECT DISTINCT v.Name, v.Sort
                           FROM inventory.TransferPostingLines rl
                           INNER JOIN (VALUES (N'DAMAGED', N'Damaged', 1), (N'MISSING', N'Missing / stolen', 2),
                                              (N'DISPATCHCOUNT', N'Wrongly counted at dispatch', 3), (N'OTHER', N'Other', 4)) v (Code, Name, Sort)
                                   ON v.Code = rl.LossReasonCode
                           WHERE rl.PostingId = @PostingId AND rl.LostBase > 0) n) rs;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PostingId = @PostingId, DocumentNumber = @DocumentNumber, ReceivedBase = @Received, LostBase = @Lost;
END

GO

