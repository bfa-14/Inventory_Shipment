-- happened to the link, 65023 / 65017 when its approver may not decide; else returns the link. The order is read
-- with UPDLOCK: inside Decide's transaction a second click waits for the first decision, then gets its message.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_CheckToken
    @Token      VARCHAR(64),
    @ApprovalId INT OUTPUT,
    @DocumentId INT OUTPUT,
    @ApproverId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @ApprovalId = NULL, @DocumentId = NULL, @ApproverId = NULL;

    DECLARE @Raw VARBINARY(32) = CASE WHEN LEN(@Token) = 64 THEN TRY_CONVERT(VARBINARY(32), @Token, 2) END;
    IF @Raw IS NULL THROW 65014, 'This approval link is not valid.', 1;

    DECLARE @LinkStatus TINYINT, @Expires DATETIME2(3), @LinkAt DATETIME2(3), @LinkDecidedAt DATETIME2(3), @ClosedBy BIGINT,
            @DocStatus TINYINT, @ApprovedAt DATETIME2(3), @ApprovedBy INT, @RejectedAt DATETIME2(3), @RejectedBy INT;

    SELECT @ApprovalId = a.Id, @DocumentId = a.DocumentId, @ApproverId = a.ApproverUserId, @LinkStatus = a.Status,
           @Expires = a.ExpiresAtUtc, @LinkAt = a.RequestedAtUtc, @LinkDecidedAt = a.DecidedAtUtc, @ClosedBy = a.ClosedByEventId
    FROM purchase.PurchaseOrderApprovals a
    WHERE a.TokenHash = HASHBYTES('SHA2_256', @Raw);
    IF @ApprovalId IS NULL THROW 65014, 'This approval link is not valid.', 1;

    SELECT @DocStatus = d.Status, @ApprovedAt = d.ApprovedAtUtc, @ApprovedBy = d.ApprovedBy,
           @RejectedAt = d.RejectedAtUtc, @RejectedBy = d.RejectedBy
    FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
    WHERE d.Id = @DocumentId;

    IF @LinkStatus <> 1 OR @DocStatus <> 5
    BEGIN
        -- What happened: an approved order says by whom; otherwise the event that closed this link.
        DECLARE @EvType TINYINT, @EvAt DATETIME2(3), @EvUser INT;
        IF @ApprovedAt >= @LinkAt
            SELECT @EvType = 4, @EvAt = @ApprovedAt, @EvUser = @ApprovedBy;
        ELSE IF @ClosedBy IS NOT NULL
            SELECT @EvType = e.EventType, @EvAt = e.AtUtc, @EvUser = e.UserId
            FROM purchase.PurchaseOrderApprovalEvents e WHERE e.Id = @ClosedBy;
        ELSE                    -- links of script 26 (no history): what the order itself says
            SELECT @EvType = CASE WHEN @RejectedAt >= @LinkAt THEN 5
                                  WHEN @LinkStatus = 4 AND @DocStatus = 1 THEN 6 END,
                   @EvAt   = CASE WHEN @RejectedAt >= @LinkAt THEN @RejectedAt ELSE @LinkDecidedAt END,
                   @EvUser = CASE WHEN @RejectedAt >= @LinkAt THEN @RejectedBy END;

        DECLARE @Who NVARCHAR(100) = ISNULL((SELECT FullName FROM security.Users WHERE Id = @EvUser), N'another user');
        DECLARE @On NVARCHAR(30) = ISNULL(FORMAT(@EvAt, N'd MMM yyyy', N'en-US'), N'an earlier date');
        DECLARE @Msg NVARCHAR(400) =
            CASE @EvType
                WHEN 4 THEN N'This order was already approved by ' + @Who + N' on ' + @On + N'.'
                WHEN 5 THEN N'This order was rejected by ' + @Who + N' on ' + @On + N'.'
                WHEN 6 THEN N'This request was withdrawn on ' + @On + N'.'
                ELSE CASE WHEN @LinkStatus IN (2, 3) THEN N'This link was already used.'
                          ELSE N'This purchase order is no longer waiting for approval.' END
            END;
        THROW 65014, @Msg, 1;
    END

    IF @Expires < SYSUTCDATETIME()
        THROW 65014, 'This link has expired: ask for a new email, or approve in the application.', 1;

    EXEC purchase.usp_PurchaseOrder_CheckApprover @PurchaseDocumentId = @DocumentId, @UserId = @ApproverId, @Channel = 2;
END

GO

