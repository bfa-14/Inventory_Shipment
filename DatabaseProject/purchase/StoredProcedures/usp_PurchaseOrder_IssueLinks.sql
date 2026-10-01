-- approvers, the history event, the audit line. Runs inside the caller's transaction (its TRY/CATCH rolls back).
-- The caller creates #IssuedLinks (see usp_PurchaseOrder_RequestApproval) and returns its rows: the tokens exist only
-- there, the table keeps their SHA-256 hash.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_IssueLinks
    @PurchaseDocumentId INT,
    @EventType          TINYINT,         -- 1 sent for approval (a new request), 2 reminder, 3 sent again
    @UserId             INT = NULL,      -- who did it; NULL = the application (reminders)
    @ValidHours         INT = NULL       -- NULL = ApprovalSettings.LinkValidHours
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT = 0 THROW 65000, 'usp_PurchaseOrder_IssueLinks runs inside the transaction of its caller.', 1;
    IF @EventType NOT IN (1, 2, 3) THROW 65000, 'Unknown request event.', 1;

    DECLARE @SettingHours INT, @NotifyApp BIT, @AllowSelf BIT;
    SELECT @SettingHours = LinkValidHours, @NotifyApp = NotifyAppApprovers, @AllowSelf = AllowSelfApproval
    FROM purchase.ApprovalSettings WHERE Id = 1;
    IF @ValidHours IS NULL OR @ValidHours < 1 SET @ValidHours = ISNULL(@SettingHours, 72);
    SELECT @NotifyApp = ISNULL(@NotifyApp, 1), @AllowSelf = ISNULL(@AllowSelf, 1);

    DECLARE @Approvers TABLE (Seq INT IDENTITY(1, 1) PRIMARY KEY, UserId INT NOT NULL, FullName NVARCHAR(100) NOT NULL,
                              Email NVARCHAR(256) NULL, CanApproveInApp BIT NOT NULL, CanApproveByEmail BIT NOT NULL,
                              Token VARBINARY(32) NULL);
    INSERT INTO @Approvers (UserId, FullName, Email, CanApproveInApp, CanApproveByEmail)
    SELECT UserId, FullName, Email, CanApproveInApp, CanApproveByEmail
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
    ORDER BY FullName;

    -- a new request: its sender is not in the history yet
    IF @EventType = 1 AND @AllowSelf = 0
        DELETE FROM @Approvers WHERE UserId = @UserId;

    IF NOT EXISTS (SELECT 1 FROM @Approvers)
        THROW 65015, 'Nobody can approve this order: choose the approvers in Settings > Purchase approval.', 1;

    -- One cryptographic token per by-email approver (generated row by row).
    DECLARE @Seq INT = 1, @Max INT = (SELECT MAX(Seq) FROM @Approvers);
    WHILE @Seq <= @Max
    BEGIN
        UPDATE @Approvers SET Token = CRYPT_GEN_RANDOM(32) WHERE Seq = @Seq AND CanApproveByEmail = 1;
        SET @Seq += 1;
    END

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Expires DATETIME2(3) = DATEADD(HOUR, @ValidHours, @Now);

    -- Number of the request: one more for a new request; reminders and "sent again" belong to the current one.
    DECLARE @LinkNo INT = ISNULL((SELECT MAX(RequestNo) FROM purchase.PurchaseOrderApprovals WHERE DocumentId = @PurchaseDocumentId), 0),
            @SentNo INT = (SELECT COUNT(*) FROM purchase.PurchaseOrderApprovalEvents WHERE PurchaseDocumentId = @PurchaseDocumentId AND EventType = 1);
    DECLARE @RequestNo INT = CASE WHEN @LinkNo > @SentNo THEN @LinkNo ELSE @SentNo END;
    IF @EventType = 1
    BEGIN
        SET @RequestNo += 1;
        -- a new request closes the links of the previous one (script 26)
        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = @Now
        WHERE DocumentId = @PurchaseDocumentId AND Status = 1;
    END
    ELSE IF @RequestNo = 0
        SET @RequestNo = 1;

    INSERT INTO purchase.PurchaseOrderApprovals (DocumentId, RequestNo, ApproverUserId, TokenHash, ExpiresAtUtc, RequestedBy, RequestedAtUtc)
    SELECT @PurchaseDocumentId, @RequestNo, a.UserId, HASHBYTES('SHA2_256', a.Token), @Expires,
           ISNULL(@UserId, (SELECT ApprovalRequestedBy FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId)), @Now
    FROM @Approvers a
    WHERE a.Token IS NOT NULL;

    INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Recipients)
    SELECT @PurchaseDocumentId, @EventType, @UserId,
           LEFT(STRING_AGG(CAST(a.FullName + N' ('
                                + CASE WHEN a.CanApproveInApp = 1 AND a.CanApproveByEmail = 1 THEN N'in the app and by email'
                                       WHEN a.CanApproveByEmail = 1 THEN N'by email'
                                       ELSE N'in the app' END + N')' AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY a.FullName), 1000)
    FROM @Approvers a;

    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@PurchaseDocumentId, N'Updated',
            CASE @EventType WHEN 1 THEN N'Sent for approval to ' WHEN 2 THEN N'Approval reminder sent to '
                            ELSE N'Sent again for approval to ' END
            + CAST((SELECT COUNT(*) FROM @Approvers) AS NVARCHAR(10)) + N' approver(s)', @UserId);

    INSERT INTO #IssuedLinks (PurchaseDocumentId, UserId, FullName, Email, Token, ExpiresAtUtc, RequestNo, Channel,
                              CanApproveInApp, SendEmail)
    SELECT @PurchaseDocumentId, a.UserId, a.FullName, a.Email,
           CASE WHEN a.Token IS NOT NULL THEN CONVERT(VARCHAR(64), a.Token, 2) END,
           CASE WHEN a.Token IS NOT NULL THEN @Expires END,
           @RequestNo,
           CASE WHEN a.CanApproveByEmail = 1 THEN N'Email' ELSE N'App' END,
           a.CanApproveInApp,
           CASE WHEN a.CanApproveByEmail = 1 THEN 1
                WHEN a.Email IS NOT NULL AND @NotifyApp = 1 THEN 1
                ELSE 0 END
    FROM @Approvers a;
END

GO

