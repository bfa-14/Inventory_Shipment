/* 13.9 SEND FOR APPROVAL (Blocks, SendForApproval: the TRO type asks for approval, a draft, the Release checks): the
   order waits, locked, until an approver approves or rejects it or the requester withdraws it; a rejection shown on
   the draft is cleared. The number does not change (the email says "a transfer order" while it has none).
   Result set 1 = the approvers to tell (inventory.usp_TransferOrder_Approvers, the requester left out): the API emails
   them after this transaction; the audit names them. */
CREATE   PROCEDURE inventory.usp_TransferOrder_SendForApproval
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(), @Told NVARCHAR(500), @Count INT;
    DECLARE @A TABLE (UserId INT NOT NULL PRIMARY KEY, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'SendForApproval' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        UPDATE inventory.TransferOrders
        SET Status = 4, ApprovalRequestedAtUtc = @Now, ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO @A (UserId, FullName, Email)
        EXEC inventory.usp_TransferOrder_Approvers @RequesterId = @UserId;

        -- "Approvers told: Manager One, Approver T90 and 2 more." (the first three by name)
        SET @Count = (SELECT COUNT(*) FROM @A);
        SET @Told = STUFF((SELECT TOP (3) N', ' + a.FullName FROM @A a ORDER BY a.FullName, a.UserId
                           FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(500)'), 1, 2, N'');
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'SentForApproval',
                LEFT(CASE WHEN @Count = 0 THEN N'Nobody else may approve transfer orders: no approver was told.'
                          ELSE N'Approvers told: ' + @Told
                               + CASE WHEN @Count > 3 THEN N' and ' + CAST(@Count - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END + N'.' END, 500),
                @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email FROM @A ORDER BY FullName, UserId;
END

GO

