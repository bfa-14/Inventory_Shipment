/* 13.13 BACK TO DRAFT (Blocks, BackToDraft: a released order with NO posting at all, reversed or not - D3: Save
   replaces the lines and posting lines must never lose their order line; then the reason). Its approval and release
   stamps are cleared: it is released, and approved when the type asks for it, again afterwards. The number stays. */
CREATE   PROCEDURE inventory.usp_TransferOrder_BackToDraft
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'BackToDraft' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to take the order back to draft.', 1;

        UPDATE inventory.TransferOrders
        SET Status = 1,
            ApprovalRequestedAtUtc = NULL, ApprovalRequestedBy = NULL,
            ApprovedAtUtc = NULL, ApprovedBy = NULL, ApprovedDirectly = 0,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            ReleasedAtUtc = NULL, ReleasedBy = NULL,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'BackToDraft', LEFT(@Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

