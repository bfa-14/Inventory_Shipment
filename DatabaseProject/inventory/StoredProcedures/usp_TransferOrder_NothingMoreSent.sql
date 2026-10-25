/* 13.21 NOTHING MORE WILL BE SENT (Blocks, NothingMoreSent: a released order with something dispatched and something
   left to dispatch, not closed yet; then the reason; FB decision 6). What is left to dispatch on every line becomes Not
   sent; Ordered stays as it is; goods on the way can still be received; a dispatch reversed afterwards adds its pieces
   to Not sent (usp_TransferPosting_Reverse). No reopen: a new order covers it. */
CREATE   PROCEDURE inventory.usp_TransferOrder_NothingMoreSent
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(), @NotSent INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'NothingMoreSent' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required: why will nothing more be sent?', 1;

        SELECT @NotSent = ISNULL(SUM(CASE WHEN OrderedBase - DispatchedBase - NotSentBase > 0
                                          THEN OrderedBase - DispatchedBase - NotSentBase ELSE 0 END), 0)
        FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;

        UPDATE inventory.TransferOrderLines
        SET NotSentBase = NotSentBase + CASE WHEN OrderedBase - DispatchedBase - NotSentBase > 0
                                             THEN OrderedBase - DispatchedBase - NotSentBase ELSE 0 END
        WHERE TransferOrderId = @Id;

        UPDATE inventory.TransferOrders
        SET NotSentAtUtc = @Now, NotSentBy = @UserId, NotSentReason = @Reason,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'NothingMoreSent', LEFT(CAST(@NotSent AS NVARCHAR(20)) + N' pcs not sent: ' + @Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

