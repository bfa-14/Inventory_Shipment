/* 13.11 REJECT (Blocks, Reject: the approval right, an order waiting for approval; then the reason): back to draft,
   showing "Rejected by {name} on {date}: {reason}" until it is sent again. Result set 1 = the requester to tell
   ("Rejected: transfer order ..."): RequestedById, RequestedByName, RequestedByEmail. */
CREATE   PROCEDURE inventory.usp_TransferOrder_Reject
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @RequestedBy INT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @RequestedBy = ApprovalRequestedBy
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Reject' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to reject the order.', 1;

        UPDATE inventory.TransferOrders
        SET Status = 1, RejectedAtUtc = @Now, RejectedBy = @UserId, RejectReason = @Reason,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'Rejected', LEFT(@Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT RequestedById = u.Id, RequestedByName = u.FullName, RequestedByEmail = u.Email
    FROM security.Users u
    WHERE u.Id = @RequestedBy;
END

GO

