-- caller's transaction (its TRY/CATCH rolls back) and returns nothing. The decision closes every other open link.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_ApplyDecision
    @PurchaseDocumentId INT,
    @Approve            BIT,
    @Reason             NVARCHAR(500) = NULL,
    @UserId             INT,
    @Channel            TINYINT,                -- 1 in the app, 2 by email
    @ApprovalId         INT           = NULL,   -- the emailed link used; NULL = the user's latest open link, if any
    @Note               NVARCHAR(200) = NULL    -- on the history event
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT = 0 THROW 65000, 'usp_PurchaseOrder_ApplyDecision runs inside the transaction of its caller.', 1;
    IF @Channel IS NULL OR @Channel NOT IN (1, 2) THROW 65000, 'Unknown approval channel.', 1;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    DECLARE @ChannelText NVARCHAR(10) = CASE WHEN @Channel = 2 THEN N'Email' ELSE N'App' END;
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    IF @Approve = 1
    BEGIN
        EXEC purchase.usp_PurchaseDocument_Post @Id = @PurchaseDocumentId, @RowVersion = NULL, @UserId = @UserId, @FromApproval = 1;

        UPDATE purchase.PurchaseDocuments
        SET ApprovedAtUtc = @Now, ApprovedBy = @UserId, ApprovalChannel = @ChannelText
        WHERE Id = @PurchaseDocumentId;
    END
    ELSE
    BEGIN
        UPDATE purchase.PurchaseDocuments
        SET Status = 1, RejectedAtUtc = @Now, RejectedBy = @UserId, RejectReason = LEFT(@Reason, 300),
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @PurchaseDocumentId AND Status = 5;
        IF @@ROWCOUNT = 0 THROW 65010, 'Only a purchase order waiting for approval can be rejected.', 1;
    END

    INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, Channel, UserId, Reason, Note)
    VALUES (@PurchaseDocumentId, CASE WHEN @Approve = 1 THEN 4 ELSE 5 END, @Channel, @UserId, @Reason, @Note);
    DECLARE @EventId BIGINT = SCOPE_IDENTITY();

    IF @ApprovalId IS NULL
        SELECT TOP (1) @ApprovalId = Id FROM purchase.PurchaseOrderApprovals
        WHERE DocumentId = @PurchaseDocumentId AND Status = 1 AND ApproverUserId = @UserId
        ORDER BY RequestNo DESC, Id DESC;

    UPDATE purchase.PurchaseOrderApprovals
    SET Status = CASE WHEN Id = @ApprovalId THEN CASE WHEN @Approve = 1 THEN 2 ELSE 3 END ELSE 4 END,
        DecidedAtUtc = @Now,
        DecisionNote = CASE WHEN Id = @ApprovalId THEN LEFT(@Reason, 300) ELSE DecisionNote END,
        Channel = CASE WHEN Id = @ApprovalId THEN @ChannelText ELSE Channel END,
        ClosedByEventId = @EventId
    WHERE DocumentId = @PurchaseDocumentId AND Status = 1;

    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@PurchaseDocumentId, CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
            LEFT(CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END + N' by '
                 + ISNULL((SELECT FullName FROM security.Users WHERE Id = @UserId), N'?')
                 + CASE WHEN @Channel = 2 THEN N' from the email link' ELSE N' in the application' END
                 + ISNULL(N' (' + @Note + N')', N'')
                 + ISNULL(N': ' + @Reason, N''), 500), @UserId);
END

GO

