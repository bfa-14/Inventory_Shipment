/* 13.22 CANCEL ORDER (Blocks, Cancel: a released order with nothing dispatched - a reversed dispatch counts as none - then
   the reason; FB decision 9). No stock effect; the order keeps its number. A draft is deleted instead, an order waiting
   for approval is withdrawn first. */
CREATE   PROCEDURE inventory.usp_TransferOrder_Cancel
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Cancel' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A cancellation reason is required.', 1;

        UPDATE inventory.TransferOrders
        SET Status = 3, CancelledAtUtc = @Now, CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'Cancelled', LEFT(@Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

