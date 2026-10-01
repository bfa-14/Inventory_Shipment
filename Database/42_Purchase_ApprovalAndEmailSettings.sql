/* =====================================================================================
   Inventory_Shipment - 42: PURCHASE APPROVAL SETTINGS + EMAIL SETTINGS
   (planned as "script 29" in batch 10; 29 to 41 were already taken by the scripts of AJ's commits)

   Purchase approval: the rules and the approvers come from Settings > Purchase approval, no longer from the
   permission purchase.orders.approve (kept, renamed "(not used)").
     purchase.ApprovalSettings (one row, Id = 1)
       RequireApproval       0 = every purchase order is posted directly
       ApprovalLimitBase     an order whose total in the base currency is not above it is posted directly; 0 = none is
       AllowSelfApproval     0 = neither the creator of an order nor the user who sent it for approval may approve it
       LinkValidHours        validity of the emailed links (was fixed at 72)
       ReminderHours         new links for the approvers of an order still waiting after that many hours; 0 = never
       NotifyAppApprovers    in-app approvers are told by email (a link to the order, no approval link)
       EmailSupplierOnApproval, CopyToOwners, CopyToEmails   what the API sends after an approval
     purchase.OrderApprovers  who approves: in the app, by email (needs an address), or both. The first run makes the
       administrators (active users of a system role) approvers; Owner and Manager users approve only once ticked in
       the settings page.
     purchase.PurchaseOrderApprovalEvents  the approval history of an order (event types: see the table).
     purchase.PurchaseOrderApprovals.ClosedByEventId (new column, script 26 table)  the decision / withdrawal that closed
       a link: event times are kept to the second, so a used link finds what happened by this id, not by time.
     messaging.EmailSettings (one row, Id = 1)  the mail server, the sender, the address of the application used in the
       links of the emails. UpdatedAtUtc NULL = never saved from the page: the API keeps using appsettings. The password
       is encrypted by the API; only usp_EmailSettings_GetForSending returns it.

   Rules of this batch
     - A purchase order needs approval when RequireApproval = 1 and (ApprovalLimitBase = 0 or its base total is above
       it): purchase.fn_PurchaseOrder_NeedsApproval. Otherwise usp_PurchaseDocument_Post posts it directly (approved by
       the user who posts it, event 7) and usp_PurchaseOrder_RequestApproval refuses it (65022).
     - Approvers of an order (purchase.fn_PurchaseOrder_Approvers): the ACTIVE users of purchase.OrderApprovers; "by
       email" only with an address; with AllowSelfApproval = 0, neither its creator nor the user who sent it.
     - Personal links only for the by-email approvers. Every request (sent, sent again, reminder) returns one row per
       approver: Channel Email | App, and SendEmail = 1 for Email, and for App when NotifyAppApprovers = 1 and the
       approver has an address. In-app approvers decide with usp_PurchaseOrder_DecideInApp.
     - Approve directly (usp_PurchaseOrder_ApproveDirect): a draft that needs approval, by an in-app approver, while
       self-approval is allowed.
     - A link that cannot be used says why: approved by whom and when, rejected, withdrawn, expired, already used.
     - The API calls usp_PurchaseOrder_DueReminders on a timer and emails the rows it returns.
     - The decision procedures share usp_PurchaseOrder_ApplyDecision; the internal procedures (_CheckApprover,
       _CheckToken, _IssueLinks, _ApplyDecision, _DecisionResult) are not called by the API.

   Errors: 65000 validation, 65004 concurrency, 65006 not found, 65010 invalid status,
           65013 the order needs approval (Post), 65014 the link cannot be used (the message says why),
           65015 nobody can approve the order, 65017 not an approver (in the app / by email),
           65022 approval not needed, 65023 self-approval refused, 65024 approval settings, 65025 email settings.
           (Planned as 65018-65021: those numbers belong to script 27 - exporter reference, container lines,
           charges on the containers, order shipped in containers.)
   Permissions: settings.email.manage (921) and purchase.approval.manage (1051), granted to the system roles.

   Requires script 26. Idempotent: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.PurchaseOrderApprovals', N'U') IS NULL
BEGIN
    RAISERROR ('Run script 26 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'purchase.ApprovalSettings', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.ApprovalSettings
    (
        Id                      TINYINT        NOT NULL CONSTRAINT PK_ApprovalSettings PRIMARY KEY,
        RequireApproval         BIT            NOT NULL CONSTRAINT DF_ApprovalSettings_RequireApproval DEFAULT (1),
        ApprovalLimitBase       DECIMAL(19, 4) NOT NULL CONSTRAINT DF_ApprovalSettings_ApprovalLimitBase DEFAULT (0),
        AllowSelfApproval       BIT            NOT NULL CONSTRAINT DF_ApprovalSettings_AllowSelfApproval DEFAULT (1),
        LinkValidHours          INT            NOT NULL CONSTRAINT DF_ApprovalSettings_LinkValidHours DEFAULT (72),
        ReminderHours           INT            NOT NULL CONSTRAINT DF_ApprovalSettings_ReminderHours DEFAULT (24),
        NotifyAppApprovers      BIT            NOT NULL CONSTRAINT DF_ApprovalSettings_NotifyAppApprovers DEFAULT (1),
        EmailSupplierOnApproval BIT            NOT NULL CONSTRAINT DF_ApprovalSettings_EmailSupplier DEFAULT (1),
        CopyToOwners            BIT            NOT NULL CONSTRAINT DF_ApprovalSettings_CopyToOwners DEFAULT (1),
        CopyToEmails            NVARCHAR(1000) NULL,
        UpdatedAtUtc            DATETIME2(0)   NULL,
        UpdatedBy               INT            NULL,
        RowVersion              ROWVERSION     NOT NULL,
        CONSTRAINT CK_ApprovalSettings_Id             CHECK (Id = 1),
        CONSTRAINT CK_ApprovalSettings_Limit          CHECK (ApprovalLimitBase >= 0),
        CONSTRAINT CK_ApprovalSettings_LinkValidHours CHECK (LinkValidHours BETWEEN 1 AND 720),
        CONSTRAINT CK_ApprovalSettings_ReminderHours  CHECK (ReminderHours BETWEEN 0 AND 168),
        CONSTRAINT FK_ApprovalSettings_UpdatedBy      FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created purchase.ApprovalSettings';
END
GO

IF OBJECT_ID(N'purchase.OrderApprovers', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.OrderApprovers
    (
        UserId            INT          NOT NULL CONSTRAINT PK_OrderApprovers PRIMARY KEY,
        CanApproveInApp   BIT          NOT NULL,
        CanApproveByEmail BIT          NOT NULL,
        UpdatedAtUtc      DATETIME2(0) NOT NULL CONSTRAINT DF_OrderApprovers_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()),
        UpdatedBy         INT          NULL,
        CONSTRAINT CK_OrderApprovers_AnyRight  CHECK (CanApproveInApp = 1 OR CanApproveByEmail = 1),
        CONSTRAINT FK_OrderApprovers_User      FOREIGN KEY (UserId)    REFERENCES security.Users (Id),
        CONSTRAINT FK_OrderApprovers_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created purchase.OrderApprovers';
END
GO

IF OBJECT_ID(N'purchase.PurchaseOrderApprovalEvents', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseOrderApprovalEvents
    (
        Id                 BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PurchaseOrderApprovalEvents PRIMARY KEY,
        PurchaseDocumentId INT            NOT NULL,
        EventType          TINYINT        NOT NULL,  -- 1 sent for approval, 2 reminder sent, 3 sent again, 4 approved,
                                                     -- 5 rejected, 6 withdrawn, 7 posted without approval,
                                                     -- 8 sent to the supplier, 9 not sent to the supplier (no address)
        Channel            TINYINT        NULL,      -- 1 in the app, 2 by email (approved / rejected only)
        UserId             INT            NULL,      -- who did it; NULL = the application (reminders, automatic emails)
        Recipients         NVARCHAR(1000) NULL,
        Reason             NVARCHAR(500)  NULL,
        Note               NVARCHAR(200)  NULL,
        AtUtc              DATETIME2(0)   NOT NULL CONSTRAINT DF_PurchaseOrderApprovalEvents_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_PurchaseOrderApprovalEvents_Type     CHECK (EventType BETWEEN 1 AND 9),
        CONSTRAINT CK_PurchaseOrderApprovalEvents_Channel  CHECK (Channel IS NULL OR Channel IN (1, 2)),
        CONSTRAINT FK_PurchaseOrderApprovalEvents_Document FOREIGN KEY (PurchaseDocumentId)
            REFERENCES purchase.PurchaseDocuments (Id) ON DELETE CASCADE,
        CONSTRAINT FK_PurchaseOrderApprovalEvents_User     FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE INDEX IX_PurchaseOrderApprovalEvents_Document ON purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, AtUtc);
    PRINT 'Created purchase.PurchaseOrderApprovalEvents';
END
GO

-- The event (approved / rejected / withdrawn) that closed an emailed link, so a used link says what happened to it.
-- Event times are kept to the second: two events of the same second cannot be told apart by time.
IF COL_LENGTH(N'purchase.PurchaseOrderApprovals', N'ClosedByEventId') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseOrderApprovals ADD ClosedByEventId BIGINT NULL;
    PRINT 'PurchaseOrderApprovals: added ClosedByEventId';
END
GO

IF OBJECT_ID(N'messaging.EmailSettings', N'U') IS NULL
BEGIN
    CREATE TABLE messaging.EmailSettings
    (
        Id                    TINYINT        NOT NULL CONSTRAINT PK_EmailSettings PRIMARY KEY,
        SendingEnabled        BIT            NOT NULL CONSTRAINT DF_EmailSettings_SendingEnabled DEFAULT (0),
        SmtpHost              NVARCHAR(200)  NULL,
        SmtpPort              INT            NOT NULL CONSTRAINT DF_EmailSettings_SmtpPort DEFAULT (587),
        SmtpSecurity          TINYINT        NOT NULL CONSTRAINT DF_EmailSettings_SmtpSecurity DEFAULT (1),  -- 0 none, 1 STARTTLS, 2 SSL/TLS
        SmtpUserName          NVARCHAR(256)  NULL,
        SmtpPasswordProtected NVARCHAR(MAX)  NULL,   -- encrypted by the API (Data Protection); never sent to the browser
        FromAddress           NVARCHAR(256)  NULL,
        FromName              NVARCHAR(200)  NULL,
        ReplyToAddress        NVARCHAR(256)  NULL,
        PublicBaseUrl         NVARCHAR(300)  NULL,   -- address of the web application, used in the links of the emails
        LastTestAtUtc         DATETIME2(0)   NULL,
        LastTestOk            BIT            NULL,
        LastTestError         NVARCHAR(1000) NULL,
        UpdatedAtUtc          DATETIME2(0)   NULL,   -- NULL = never saved from the page: the API uses appsettings
        UpdatedBy             INT            NULL,
        RowVersion            ROWVERSION     NOT NULL,
        CONSTRAINT CK_EmailSettings_Id        CHECK (Id = 1),
        CONSTRAINT CK_EmailSettings_Port      CHECK (SmtpPort BETWEEN 1 AND 65535),
        CONSTRAINT CK_EmailSettings_Security  CHECK (SmtpSecurity IN (0, 1, 2)),
        CONSTRAINT FK_EmailSettings_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created messaging.EmailSettings';
END
GO

/* ================================================================== 2. Type */

IF TYPE_ID(N'purchase.tvp_OrderApprover') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_OrderApprover AS TABLE
    (
        UserId            INT NOT NULL PRIMARY KEY,
        CanApproveInApp   BIT NOT NULL,
        CanApproveByEmail BIT NOT NULL
    );
    PRINT 'Created type purchase.tvp_OrderApprover';
END
GO

/* ================================================================== 3. Permissions */

-- Each one sits in the module of its neighbour, right after it in the list.
MERGE security.Permissions AS target
USING
(
    SELECT N'settings.email.manage', N'Manage Email Settings',
           ISNULL((SELECT Module FROM security.Permissions WHERE Code = N'messaging.emails.view'), N'Configuration'),
           N'Set the mail server and the sender address used for every email the application sends.', 921
    UNION ALL
    SELECT N'purchase.approval.manage', N'Manage Purchase Approval Settings',
           ISNULL((SELECT Module FROM security.Permissions WHERE Code = N'purchase.orders.approve'), N'Purchase'),
           N'Decide whether purchase orders need approval and who approves them, in the app or by email.', 1051
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE r.IsSystem = 1
  AND p.Code IN (N'settings.email.manage', N'purchase.approval.manage')
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- The approvers are chosen in Settings > Purchase approval. Script 26 gives the old name back at every start-up;
-- this script runs after it, so this is the final state.
UPDATE security.Permissions
SET Name = N'Approve Purchase Orders (not used)',
    Description = N'No effect since script 42: the approvers are chosen in Settings > Purchase approval.'
WHERE Code = N'purchase.orders.approve';
GO

/* ================================================================== 4. First run */

-- Once: the default rules, and the administrators as approvers (in the app; by email when they have an address).
-- Nobody else: Owner and Manager users approve once ticked in the settings page.
IF NOT EXISTS (SELECT 1 FROM purchase.ApprovalSettings)
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    INSERT INTO purchase.ApprovalSettings (Id) VALUES (1);

    INSERT INTO purchase.OrderApprovers (UserId, CanApproveInApp, CanApproveByEmail)
    SELECT u.Id, 1, CASE WHEN NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL THEN 1 ELSE 0 END
    FROM security.Users u
    WHERE u.IsActive = 1
      AND EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                  WHERE ur.UserId = u.Id AND r.IsSystem = 1)
      AND NOT EXISTS (SELECT 1 FROM purchase.OrderApprovers a WHERE a.UserId = u.Id);

    COMMIT TRANSACTION;
    PRINT 'Approval settings: defaults, the administrators are the approvers';
END
GO

IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings)
BEGIN
    INSERT INTO messaging.EmailSettings (Id) VALUES (1);
    PRINT 'Email settings: empty row (the API uses appsettings until the page saves it)';
END
GO

/* ================================================================== 5. Helpers */

-- 1 when the purchase order must be approved before it is posted. No settings row = 1 (as in script 26).
CREATE OR ALTER FUNCTION purchase.fn_PurchaseOrder_NeedsApproval (@PurchaseDocumentId INT)
RETURNS BIT
AS
BEGIN
    DECLARE @Require BIT, @Limit DECIMAL(19, 4), @Total DECIMAL(19, 4);
    SELECT @Require = RequireApproval, @Limit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;

    IF @Require IS NULL RETURN 1;
    IF @Require = 0 RETURN 0;
    IF @Limit = 0 RETURN 1;

    SELECT @Total = TotalAmountBase FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId;
    RETURN CASE WHEN @Total IS NULL OR @Total > @Limit THEN 1 ELSE 0 END;
END
GO

-- The approvers of a purchase order (NULL = every active approver): "by email" only with an address, a user left
-- without a right is not returned; with AllowSelfApproval = 0, neither the creator of the order nor the user who sent
-- it for approval (its latest event 1; for an order sent before script 42: the requester stored by script 26).
CREATE OR ALTER FUNCTION purchase.fn_PurchaseOrder_Approvers (@PurchaseDocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT a.UserId, u.FullName, e.Email, a.CanApproveInApp,
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND e.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM purchase.OrderApprovers a
    INNER JOIN security.Users u ON u.Id = a.UserId AND u.IsActive = 1
    CROSS APPLY (SELECT Email = NULLIF(LTRIM(RTRIM(u.Email)), N'')) e
    LEFT  JOIN purchase.ApprovalSettings s ON s.Id = 1
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = @PurchaseDocumentId
    OUTER APPLY (SELECT TOP (1) ev.UserId FROM purchase.PurchaseOrderApprovalEvents ev
                 WHERE ev.PurchaseDocumentId = d.Id AND ev.EventType = 1
                 ORDER BY ev.AtUtc DESC, ev.Id DESC) sent
    WHERE (a.CanApproveInApp = 1 OR (a.CanApproveByEmail = 1 AND e.Email IS NOT NULL))
      AND (ISNULL(s.AllowSelfApproval, 1) = 1
           OR (    a.UserId <> ISNULL(d.CreatedBy, 0)
               AND a.UserId <> ISNULL(COALESCE(sent.UserId, d.ApprovalRequestedBy), 0)))
);
GO

-- Internal: may this user decide on this order, in the app (@Channel 1) or by email (2)? Throws 65023 / 65017.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_CheckApprover
    @PurchaseDocumentId INT,
    @UserId             INT,
    @Channel            TINYINT
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL((SELECT AllowSelfApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 0
       AND EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                   WHERE d.Id = @PurchaseDocumentId
                     AND (   d.CreatedBy = @UserId
                          OR COALESCE((SELECT TOP (1) ev.UserId FROM purchase.PurchaseOrderApprovalEvents ev
                                       WHERE ev.PurchaseDocumentId = d.Id AND ev.EventType = 1
                                       ORDER BY ev.AtUtc DESC, ev.Id DESC), d.ApprovalRequestedBy) = @UserId))
        THROW 65023, 'You cannot approve an order that you created or sent for approval.', 1;

    IF @Channel = 2 AND NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                                    WHERE UserId = @UserId AND CanApproveByEmail = 1)
        THROW 65017, 'You can no longer approve purchase orders by email.', 1;

    IF @Channel = 1 AND NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                                    WHERE UserId = @UserId AND CanApproveInApp = 1)
        THROW 65017, 'You are not allowed to approve purchase orders in the app.', 1;
END
GO

-- Internal: checks an emailed link, for the approval page (GetByToken) and for Decide. Throws 65014 saying what
-- happened to the link, 65023 / 65017 when its approver may not decide; else returns the link. The order is read
-- with UPDLOCK: inside Decide's transaction a second click waits for the first decision, then gets its message.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_CheckToken
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

-- Internal: one request round for a purchase order waiting for approval - new personal links for its by-email
-- approvers, the history event, the audit line. Runs inside the caller's transaction (its TRY/CATCH rolls back).
-- The caller creates #IssuedLinks (see usp_PurchaseOrder_RequestApproval) and returns its rows: the tokens exist only
-- there, the table keeps their SHA-256 hash.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_IssueLinks
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

-- Internal: approve (posts the order: number assigned) or reject (back to draft with the reason). Runs inside the
-- caller's transaction (its TRY/CATCH rolls back) and returns nothing. The decision closes every other open link.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApplyDecision
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

-- Internal: the result set of every decision (usp_PurchaseOrder_Decide / _DecideInApp / _ApproveDirect), with what
-- the API needs for the follow-up emails. Columns of script 26 first, the new ones at the end.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DecisionResult
    @PurchaseDocumentId INT,
    @Approve            BIT,
    @UserId             INT,
    @Note               NVARCHAR(500) = NULL,
    @Channel            TINYINT,
    @Direct             BIT           = 0       -- approved directly: there is no request, so no requester
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.Id AS DocumentId, d.DocumentNumber,
           Decision = CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
           DecidedByName = du.FullName, DecisionNote = @Note, Channel = CASE WHEN @Channel = 2 THEN N'Email' ELSE N'App' END,
           sp.PartyName AS SupplierName, sp.Email AS SupplierEmail,
           cu.FullName AS CreatorName, cu.Email AS CreatorEmail,
           RequestedByName = CASE WHEN @Direct = 0 THEN rq.FullName END,
           RequestedByEmail = CASE WHEN @Direct = 0 THEN rq.Email END,
           OwnerEmails = STUFF((SELECT N';' + u.Email
                                FROM security.Users u
                                INNER JOIN security.UserRoles ur ON ur.UserId = u.Id
                                INNER JOIN security.Roles r ON r.Id = ur.RoleId AND r.Name = N'Owner'
                                WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
                                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''),
           -- script 42
           d.Status, d.RowVersion,
           DecidedBy = @UserId, DecidedByEmail = NULLIF(LTRIM(RTRIM(du.Email)), N''),
           d.CreatedBy, RequestedBy = CASE WHEN @Direct = 0 THEN d.ApprovalRequestedBy END,
           d.SupplierId, ChannelId = @Channel, Direct = @Direct,
           EmailSupplierOnApproval = CAST(ISNULL(s.EmailSupplierOnApproval, 1) AS BIT),
           CopyToOwners = CAST(ISNULL(s.CopyToOwners, 1) AS BIT),
           s.CopyToEmails
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN purchase.ApprovalSettings s ON s.Id = 1
    LEFT  JOIN security.Users du ON du.Id = @UserId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users rq ON rq.Id = d.ApprovalRequestedBy
    WHERE d.Id = @PurchaseDocumentId;
END
GO

/* ================================================================== 6. Procedures of script 26, changed */

-- 6.1 Approvers from Settings > Purchase approval: of one order, or (NULL) every active approver.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Approvers
    @PurchaseDocumentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.UserId, a.FullName, a.Email, a.CanApproveInApp, a.CanApproveByEmail
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
    ORDER BY a.FullName;
END
GO

-- 6.2 Draft PO -> Pending approval. Returns one row per approver: a personal token (shown ONCE, only its hash is kept)
-- for the by-email approvers, none for the in-app ones; SendEmail = whether the API emails that approver.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_RequestApproval
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @ValidHours INT       = NULL      -- NULL = ApprovalSettings.LinkValidHours
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @SupplierId INT;
    SELECT @TypeCode = dt.Code, @Status = d.Status, @SupplierId = d.SupplierId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @Id;

    IF @TypeCode IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders go through approval.', 1;
    IF @Status <> 1 THROW 65010, 'Only a draft purchase order can be sent for approval.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
        THROW 65009, 'The purchase order has no lines. Add at least one item before sending it for approval.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
        THROW 65008, 'The supplier is inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL)
        THROW 65016, 'The supplier has no email in Parties. Add it first: the approved order is emailed to the supplier.', 1;
    IF purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 0
        THROW 65022, 'This order does not need approval: post it.', 1;

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL,
        Token VARCHAR(64) NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = SYSUTCDATETIME(), ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status = 1;
        IF @@ROWCOUNT = 0 THROW 65010, 'Only a draft purchase order can be sent for approval.', 1;

        -- links of the by-email approvers, event 1, audit line (65015 when nobody can approve)
        EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @Id, @EventType = 1, @UserId = @UserId, @ValidHours = @ValidHours;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email, Token, ExpiresAtUtc, RequestNo, Channel, CanApproveInApp, SendEmail
    FROM #IssuedLinks
    ORDER BY FullName;
END
GO

-- 6.4 Resolves an emailed token (for the public approval page). Throws 65014 saying why a link cannot be used, and
-- 65023 / 65017 when its approver may not decide, so the page shows the reason before any click.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_GetByToken
    @Token VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ApprovalId INT, @DocumentId INT, @ApproverId INT;
    EXEC purchase.usp_PurchaseOrder_CheckToken @Token = @Token, @ApprovalId = @ApprovalId OUTPUT,
         @DocumentId = @DocumentId OUTPUT, @ApproverId = @ApproverId OUTPUT;

    SELECT a.Id AS ApprovalId, a.DocumentId, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, a.ExpiresAtUtc,
           a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.Id = @ApprovalId;
END
GO

-- 6.3 Approve or reject with an emailed token (approval page), or - kept for the callers of script 26 - as a logged-in
-- approver (@Id + @UserId; the API uses usp_PurchaseOrder_DecideInApp). Approve posts the order (number assigned).
-- Returns the data the API needs for the follow-up emails.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Decide
    @Token   VARCHAR(64)   = NULL,
    @Id      INT           = NULL,
    @UserId  INT           = NULL,
    @Approve BIT,
    @Note    NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @Approve = ISNULL(@Approve, 0);
    IF @Approve = 0 AND @Note IS NULL THROW 65000, 'A reason is required to reject a purchase order.', 1;

    DECLARE @ApprovalId INT = NULL, @DocumentId INT = NULL, @DeciderId INT = NULL, @Channel TINYINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Token IS NOT NULL
        BEGIN
            -- 65014 (what happened to the link), 65023 (self-approval), 65017 (no longer a by-email approver)
            EXEC purchase.usp_PurchaseOrder_CheckToken @Token = @Token, @ApprovalId = @ApprovalId OUTPUT,
                 @DocumentId = @DocumentId OUTPUT, @ApproverId = @DeciderId OUTPUT;
            SET @Channel = 2;
        END
        ELSE
        BEGIN
            IF @Id IS NULL OR @UserId IS NULL THROW 65000, 'The purchase order and the user are required.', 1;
            DECLARE @DocStatus TINYINT, @TypeCode NVARCHAR(20);
            SELECT @DocStatus = d.Status, @TypeCode = dt.Code
            FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
            WHERE d.Id = @Id;
            IF @DocStatus IS NULL THROW 65006, 'Document not found.', 1;
            IF @TypeCode <> N'PO' OR @DocStatus <> 5 THROW 65014, 'This purchase order is no longer waiting for approval.', 1;
            EXEC purchase.usp_PurchaseOrder_CheckApprover @PurchaseDocumentId = @Id, @UserId = @UserId, @Channel = 1;
            SELECT @DocumentId = @Id, @DeciderId = @UserId, @Channel = 1;
        END

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @DocumentId, @Approve = @Approve, @Reason = @Note,
             @UserId = @DeciderId, @Channel = @Channel, @ApprovalId = @ApprovalId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @DocumentId, @Approve = @Approve, @UserId = @DeciderId,
         @Note = @Note, @Channel = @Channel;
END
GO

-- 6.5 Pending approval -> Draft again (the requester changed their mind); the emailed links stop working.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Withdraw
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be withdrawn.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PurchaseDocuments SET Status = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id AND Status = 5;
        IF @@ROWCOUNT = 0 THROW 65010, 'Only a purchase order waiting for approval can be withdrawn.', 1;
        INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId)
        VALUES (@Id, 6, @UserId);
        DECLARE @EventId BIGINT = SCOPE_IDENTITY();
        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = SYSUTCDATETIME(), ClosedByEventId = @EventId
        WHERE DocumentId = @Id AND Status = 1;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Approval request withdrawn', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- 6.6 Re-created from script 27: a purchase order that does not need approval (settings) is posted directly
-- (@FromApproval = 0): approved by the user who posts it, event 7. One that needs approval is refused (65013) unless
-- the approval posts it (@FromApproval = 1, from "waiting for approval").
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0      -- 1 = called by the approval
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT, @ReceiptMode TINYINT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate,
               @SourceId = d.SourceDocumentId, @ReceiptMode = d.ReceiptMode
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 1 AND @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved.', 1;
        IF (@TypeCode <> N'PO' OR ISNULL(@FromApproval, 0) = 0) AND @Status <> 1
            THROW 65010, 'Only draft documents can be posted.', 1;

        DECLARE @PostedWithoutApproval BIT = CASE WHEN @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 0 THEN 1 ELSE 0 END;
        IF @PostedWithoutApproval = 1 AND purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 1
            THROW 65013, 'This order needs approval: send it for approval.', 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        -- Imports: the goods are received by the container, not by this posting.
        DECLARE @ReceiveNow BIT = CASE WHEN @TypeCode = N'PINV' AND @ReceiptMode = 2 THEN 0 ELSE 1 END;

        DECLARE @FromContainers BIT = CASE WHEN @TypeCode = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                                                                                WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END;
        IF @FromContainers = 1
        BEGIN
            IF NULLIF(LTRIM(RTRIM((SELECT ExporterReference FROM purchase.PurchaseDocuments WHERE Id = @Id))), N'') IS NULL
                THROW 65018, 'The exporter reference is required on an imported invoice. Enter it before posting.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND ContainerLineId IS NULL)
                THROW 65019, 'Every line of an invoice from containers must come from a container line.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
                THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;

            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status IN (6, 7, 8) THEN N'the container is already offloaded, closed or cancelled.'
                                           ELSE CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Posted, 0) AS NVARCHAR(20))
                                                + N' in posted invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.' END
            FROM (SELECT ContainerLineId, Here = SUM(QuantityBase) FROM purchase.PurchaseDocumentLines
                  WHERE DocumentId = @Id GROUP BY ContainerLineId) q
            INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
            OUTER APPLY (SELECT Posted = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4) AND pd.Id <> @Id) o
            WHERE c.Status IN (6, 7, 8) OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
            ORDER BY c.ContainerRef, cl.LineNumber;
            IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;
        END

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;

        IF @Direction = 1 AND @ReceiveNow = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @ReceiveNow = 1
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;

            IF @Direction = 1
                UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = QuantityBase WHERE DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @ReceiveNow = 1 THEN N' written to the stock ledger'
                                       WHEN @ReceiveNow = 0 THEN N'; stock will be received when the container is offloaded'
                                       WHEN @PostedWithoutApproval = 1 THEN N' (approval not needed)'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        -- A purchase order posted without approval: the user who posts it is recorded as approver, as an approval does.
        IF @PostedWithoutApproval = 1
        BEGIN
            UPDATE purchase.PurchaseDocuments SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @UserId WHERE Id = @Id;

            DECLARE @RequireApproval BIT, @ApprovalLimit DECIMAL(19, 4);
            SELECT @RequireApproval = RequireApproval, @ApprovalLimit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
            INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Note)
            VALUES (@Id, 7, @UserId,
                    CASE WHEN @RequireApproval = 0 THEN N'Approval not required'
                         ELSE N'Under the approval limit of ' + FORMAT(@ApprovalLimit, N'N2', N'en-US')
                              + ISNULL(N' ' + (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies
                                               WHERE IsBaseCurrency = 1 AND IsActive = 1), N'') END);
        END

        -- containers of an import: the invoice is known now (value basis of the charges, history)
        IF @FromContainers = 1
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
                INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                WHERE l.DocumentId = @Id;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@Cid, N'Updated', N'Purchase invoice ' + @Number + N' posted', @UserId);
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        COMMIT TRANSACTION;
        IF ISNULL(@FromApproval, 0) = 0 SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. New procedures */

-- 7.1 Approve or reject in the application, by an in-app approver of the order. Same result set as usp_PurchaseOrder_Decide.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DecideInApp
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8)     = NULL,
    @Approve            BIT,
    @Reason             NVARCHAR(500) = NULL,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    SET @Approve = ISNULL(@Approve, 0);
    IF @UserId IS NULL THROW 65000, 'The user is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Current BINARY(8);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Current = d.RowVersion
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved or rejected.', 1;
        IF @RowVersion IS NOT NULL AND @Current <> @RowVersion
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        EXEC purchase.usp_PurchaseOrder_CheckApprover @PurchaseDocumentId = @PurchaseDocumentId, @UserId = @UserId, @Channel = 1;
        IF @Approve = 0 AND @Reason IS NULL THROW 65000, 'A reason is required to reject a purchase order.', 1;

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @PurchaseDocumentId, @Approve = @Approve,
             @Reason = @Reason, @UserId = @UserId, @Channel = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @PurchaseDocumentId, @Approve = @Approve,
         @UserId = @UserId, @Note = @Reason, @Channel = 1;
END
GO

-- 7.2 A draft that needs approval, approved at once by an in-app approver (no request): posted like an approval.
-- Self-approval must be allowed: the user approves an order of their own here. Same result set as usp_PurchaseOrder_Decide.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApproveDirect
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @UserId IS NULL THROW 65000, 'The user is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Current BINARY(8);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Current = d.RowVersion
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 1 THROW 65010, 'Only a draft purchase order can be approved directly.', 1;
        IF @RowVersion IS NOT NULL AND @Current <> @RowVersion
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId) = 0
            THROW 65022, 'This order does not need approval: post it.', 1;
        IF ISNULL((SELECT AllowSelfApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 0
            THROW 65023, 'You cannot approve an order that you created or sent for approval.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                       WHERE UserId = @UserId AND CanApproveInApp = 1)
            THROW 65017, 'You are not allowed to approve purchase orders in the app.', 1;

        -- Post takes a purchase order only from "waiting for approval": the order passes through it here.
        UPDATE purchase.PurchaseDocuments SET Status = 5 WHERE Id = @PurchaseDocumentId;

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @PurchaseDocumentId, @Approve = 1, @Reason = NULL,
             @UserId = @UserId, @Channel = 1, @Note = N'Approved directly, without a request';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @PurchaseDocumentId, @Approve = 1,
         @UserId = @UserId, @Note = NULL, @Channel = 1, @Direct = 1;
END
GO

-- 7.3 New links for the by-email approvers of a waiting order (the older ones stay valid until they expire or the
-- order is decided). Same result rows as usp_PurchaseOrder_RequestApproval.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Resend
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL,
        Token VARCHAR(64) NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Current BINARY(8);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Current = d.RowVersion
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be sent again.', 1;
        IF @RowVersion IS NOT NULL AND @Current <> @RowVersion
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @PurchaseDocumentId, @EventType = 3, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email, Token, ExpiresAtUtc, RequestNo, Channel, CanApproveInApp, SendEmail
    FROM #IssuedLinks
    ORDER BY FullName;
END
GO

-- 7.4 Called by the API on a timer: new links (event 2) for every order waiting longer than ReminderHours since it
-- was last sent (event 1, 2 or 3; before script 42: the request date of script 26). One transaction per order; an
-- order without approver is skipped (no event), another failure is reported as an informational message and the
-- order is tried again at the next call. Returns the rows of usp_PurchaseOrder_RequestApproval for every reminded
-- order, plus PurchaseDocumentId and WaitingSinceUtc. Calling it again at once returns nothing.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DueReminders
    @MaxOrders INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @MaxOrders IS NULL OR @MaxOrders < 1 SET @MaxOrders = 50;

    DECLARE @Hours INT = ISNULL((SELECT ReminderHours FROM purchase.ApprovalSettings WHERE Id = 1), 0);

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL,
        Token VARCHAR(64) NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );
    CREATE TABLE #Due (PurchaseDocumentId INT NOT NULL PRIMARY KEY, WaitingSinceUtc DATETIME2(3) NULL, LastSentUtc DATETIME2(3) NULL);

    IF @Hours > 0
        INSERT INTO #Due (PurchaseDocumentId, WaitingSinceUtc, LastSentUtc)
        SELECT TOP (@MaxOrders) d.Id, w.WaitingSinceUtc, w.LastSentUtc
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
        CROSS APPLY (SELECT WaitingSinceUtc = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                                        WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1), d.ApprovalRequestedAtUtc),
                            LastSentUtc = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                                    WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)), d.ApprovalRequestedAtUtc)) w
        WHERE d.Status = 5
          AND w.LastSentUtc < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
        ORDER BY w.LastSentUtc, d.Id;

    DECLARE @Id INT, @LastSent DATETIME2(3), @Err NVARCHAR(2048);
    DECLARE due CURSOR LOCAL FAST_FORWARD FOR SELECT PurchaseDocumentId FROM #Due ORDER BY LastSentUtc, PurchaseDocumentId;
    OPEN due;
    FETCH NEXT FROM due INTO @Id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- still waiting and still due (another API instance may have reminded it meanwhile)
            SET @LastSent = NULL;
            SELECT @LastSent = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                         WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)), d.ApprovalRequestedAtUtc)
            FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.Id = @Id AND d.Status = 5;

            IF @LastSent < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
                EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @Id, @EventType = 2, @UserId = NULL;

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() <> 65015
            BEGIN
                SET @Err = N'Reminder of purchase order ' + CAST(@Id AS NVARCHAR(10)) + N' skipped: ' + ERROR_MESSAGE();
                RAISERROR (N'%s', 10, 1, @Err) WITH NOWAIT;
            END
        END CATCH

        FETCH NEXT FROM due INTO @Id;
    END
    CLOSE due;
    DEALLOCATE due;

    SELECT l.UserId, l.FullName, l.Email, l.Token, l.ExpiresAtUtc, l.RequestNo, l.Channel, l.CanApproveInApp, l.SendEmail,
           l.PurchaseDocumentId, d.WaitingSinceUtc
    FROM #IssuedLinks l
    INNER JOIN #Due d ON d.PurchaseDocumentId = l.PurchaseDocumentId
    ORDER BY d.LastSentUtc, l.PurchaseDocumentId, l.FullName;
END
GO

-- 7.5 The approval state of a purchase order for the order page, seen by @UserId. 2 result sets: the state, the approvers.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApprovalState
    @PurchaseDocumentId INT,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeCode NVARCHAR(20) = (SELECT dt.Code FROM purchase.PurchaseDocuments d
                                      INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                                      WHERE d.Id = @PurchaseDocumentId);
    IF @TypeCode IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders go through approval.', 1;

    DECLARE @NeedsApproval BIT = purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId);
    DECLARE @InAppApprover BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                                                   WHERE UserId = @UserId AND CanApproveInApp = 1) THEN 1 ELSE 0 END;

    SELECT d.Status,
           NeedsApproval       = @NeedsApproval,
           RequireApproval     = CAST(ISNULL(s.RequireApproval, 1) AS BIT),
           ApprovalLimitBase   = ISNULL(s.ApprovalLimitBase, 0),
           BaseCurrencyCode    = bc.CurrencyCode,
           TotalBase           = d.TotalAmountBase,
           AllowSelfApproval   = CAST(ISNULL(s.AllowSelfApproval, 1) AS BIT),
           UserCanApproveInApp = @InAppApprover,
           CanApproveDirect    = CAST(CASE WHEN d.Status = 1 AND @NeedsApproval = 1 AND ISNULL(s.AllowSelfApproval, 1) = 1
                                                AND @InAppApprover = 1 THEN 1 ELSE 0 END AS BIT),
           RequestedBy         = CASE WHEN d.Status = 5 THEN rq.UserId END,
           RequestedByName     = CASE WHEN d.Status = 5 THEN ru.FullName END,
           RequestedAtUtc      = CASE WHEN d.Status = 5 THEN rq.AtUtc END,
           LinksValidUntilUtc  = CASE WHEN d.Status = 5 THEN lk.ValidUntilUtc END,
           NextReminderAtUtc   = CASE WHEN d.Status = 5 AND s.ReminderHours > 0 THEN DATEADD(HOUR, s.ReminderHours, ls.LastSentUtc) END,
           LastRejectedByName  = CASE WHEN d.Status = 1 AND d.RejectedAtUtc IS NOT NULL THEN rju.FullName END,
           LastRejectedAtUtc   = CASE WHEN d.Status = 1 THEN d.RejectedAtUtc END,
           LastRejectReason    = CASE WHEN d.Status = 1 AND d.RejectedAtUtc IS NOT NULL THEN COALESCE(rj.Reason, d.RejectReason) END,
           SupplierEmail       = NULLIF(LTRIM(RTRIM(sp.Email)), N''),
           SentToSupplierAtUtc = se.SentAtUtc,
           SupplierNotEmailed  = CAST(CASE WHEN ne.AtUtc IS NOT NULL
                                                AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseOrderApprovalEvents x
                                                                WHERE x.PurchaseDocumentId = d.Id AND x.EventType = 8 AND x.AtUtc >= ne.AtUtc)
                                           THEN 1 ELSE 0 END AS BIT)
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN purchase.ApprovalSettings s ON s.Id = 1
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT TOP (1) e.UserId, e.AtUtc FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1 ORDER BY e.AtUtc DESC, e.Id DESC) e1
    CROSS APPLY (SELECT UserId = COALESCE(e1.UserId, d.ApprovalRequestedBy),
                        AtUtc = COALESCE(CAST(e1.AtUtc AS DATETIME2(3)), d.ApprovalRequestedAtUtc)) rq
    LEFT  JOIN security.Users ru  ON ru.Id = rq.UserId
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT ValidUntilUtc = MAX(a.ExpiresAtUtc) FROM purchase.PurchaseOrderApprovals a
                 WHERE a.DocumentId = d.Id AND a.Status = 1) lk
    OUTER APPLY (SELECT LastSentUtc = COALESCE(MAX(CAST(e.AtUtc AS DATETIME2(3))), d.ApprovalRequestedAtUtc)
                 FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)) ls
    OUTER APPLY (SELECT TOP (1) e.Reason FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 5 ORDER BY e.AtUtc DESC, e.Id DESC) rj
    OUTER APPLY (SELECT SentAtUtc = MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 8) se
    OUTER APPLY (SELECT AtUtc = MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 9
                   AND e.AtUtc >= CAST(d.ApprovedAtUtc AS DATETIME2(0))) ne
    WHERE d.Id = @PurchaseDocumentId;

    SELECT a.UserId, a.FullName, a.Email, a.CanApproveInApp, a.CanApproveByEmail,
           LinkExpiresAtUtc = (SELECT MAX(p.ExpiresAtUtc) FROM purchase.PurchaseOrderApprovals p
                               WHERE p.DocumentId = @PurchaseDocumentId AND p.ApproverUserId = a.UserId AND p.Status = 1)
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
    ORDER BY a.FullName;
END
GO

-- 7.6 The approval history of a purchase order, oldest first.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApprovalHistory
    @PurchaseDocumentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Id, e.EventType,
           EventName = CASE e.EventType WHEN 1 THEN N'Sent for approval'       WHEN 2 THEN N'Reminder sent'
                                        WHEN 3 THEN N'Sent again'              WHEN 4 THEN N'Approved'
                                        WHEN 5 THEN N'Rejected'                WHEN 6 THEN N'Withdrawn'
                                        WHEN 7 THEN N'Posted without approval' WHEN 8 THEN N'Sent to the supplier'
                                        WHEN 9 THEN N'Not sent to the supplier' END,
           e.Channel, ChannelName = CASE e.Channel WHEN 1 THEN N'In the app' WHEN 2 THEN N'By email' END,
           e.UserId, UserName = u.FullName, e.Recipients, e.Reason, e.Note, e.AtUtc
    FROM purchase.PurchaseOrderApprovalEvents e
    LEFT JOIN security.Users u ON u.Id = e.UserId
    WHERE e.PurchaseDocumentId = @PurchaseDocumentId
    ORDER BY e.AtUtc, e.Id;
END
GO

-- 7.7 The orders waiting for approval that this user can approve IN THE APP, oldest first.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_PendingForUser
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.Id,
           Reference = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10))),
           d.SupplierId, SupplierName = sp.PartyName, OrderDate = d.DocumentDate, c.CurrencyCode,
           Total = d.TotalAmount, TotalBase = d.TotalAmountBase,
           LineCount = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id),
           RequestedByName = ru.FullName, RequestedAtUtc = rq.AtUtc,
           WaitingHours = DATEDIFF(MINUTE, rq.AtUtc, SYSUTCDATETIME()) / 60,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    OUTER APPLY (SELECT TOP (1) e.UserId, e.AtUtc FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1 ORDER BY e.AtUtc DESC, e.Id DESC) e1
    CROSS APPLY (SELECT UserId = COALESCE(e1.UserId, d.ApprovalRequestedBy),
                        AtUtc = COALESCE(CAST(e1.AtUtc AS DATETIME2(3)), d.ApprovalRequestedAtUtc)) rq
    LEFT  JOIN security.Users ru ON ru.Id = rq.UserId
    WHERE d.Status = 5
      AND EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(d.Id) a WHERE a.UserId = @UserId AND a.CanApproveInApp = 1)
    ORDER BY rq.AtUtc, d.Id;
END
GO

-- 7.8 Called by the API after the approved order was emailed to the supplier (event 8), or could not be (event 9: the
-- supplier has no email address).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_SupplierEmailLogged
    @PurchaseDocumentId INT,
    @Sent               BIT,
    @Recipients         NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId) THROW 65006, 'Document not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Recipients, Note)
        VALUES (@PurchaseDocumentId, CASE WHEN @Sent = 1 THEN 8 ELSE 9 END, @UserId, NULLIF(LTRIM(RTRIM(@Recipients)), N''),
                CASE WHEN ISNULL(@Sent, 0) = 0 THEN N'The supplier has no email address' END);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. Settings procedures */

-- 8.1 Settings > Purchase approval: 1) the rules, 2) every active user and their approval rights.
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalSettings_Get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id, s.RequireApproval, s.ApprovalLimitBase, s.AllowSelfApproval, s.LinkValidHours, s.ReminderHours,
           s.NotifyAppApprovers, s.EmailSupplierOnApproval, s.CopyToOwners, s.CopyToEmails, s.UpdatedAtUtc, s.UpdatedBy,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1),
           UpdatedByName = u.FullName,
           s.RowVersion
    FROM purchase.ApprovalSettings s
    LEFT JOIN security.Users u ON u.Id = s.UpdatedBy
    WHERE s.Id = 1;

    SELECT UserId = u.Id, u.FullName, UserName = u.Username, e.Email,
           Roles = (SELECT STRING_AGG(r.Name, N', ') WITHIN GROUP (ORDER BY r.Name)
                    FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                    WHERE ur.UserId = u.Id),
           IsAdministrator = CAST(CASE WHEN EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                                                    WHERE ur.UserId = u.Id AND r.IsSystem = 1) THEN 1 ELSE 0 END AS BIT),
           CanApproveInApp = CAST(ISNULL(a.CanApproveInApp, 0) AS BIT),
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND e.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM security.Users u
    CROSS APPLY (SELECT Email = NULLIF(LTRIM(RTRIM(u.Email)), N'')) e
    LEFT JOIN purchase.OrderApprovers a ON a.UserId = u.Id
    WHERE u.IsActive = 1
    ORDER BY IsAdministrator DESC, u.FullName;
END
GO

-- 8.2 Saves the rules and makes purchase.OrderApprovers exactly @Approvers (a row with both rights 0 = not an
-- approver). Returns what usp_ApprovalSettings_Get returns.
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalSettings_Save
    @RequireApproval         BIT,
    @ApprovalLimitBase       DECIMAL(19, 4),
    @AllowSelfApproval       BIT,
    @LinkValidHours          INT,
    @ReminderHours           INT,
    @NotifyAppApprovers      BIT,
    @EmailSupplierOnApproval BIT,
    @CopyToOwners            BIT,
    @CopyToEmails            NVARCHAR(1000) = NULL,     -- checked by the API (addresses separated by ; or ,)
    @Approvers               purchase.tvp_OrderApprover READONLY,
    @RowVersion              BINARY(8)      = NULL,
    @UserId                  INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @CopyToEmails = NULLIF(LTRIM(RTRIM(@CopyToEmails)), N'');

    IF @RequireApproval IS NULL OR @ApprovalLimitBase IS NULL OR @AllowSelfApproval IS NULL OR @LinkValidHours IS NULL
       OR @ReminderHours IS NULL OR @NotifyAppApprovers IS NULL OR @EmailSupplierOnApproval IS NULL OR @CopyToOwners IS NULL
        THROW 65024, 'Every rule needs a value.', 1;
    IF @ApprovalLimitBase < 0 THROW 65024, 'The approval limit cannot be negative.', 1;
    IF @LinkValidHours NOT BETWEEN 1 AND 720 THROW 65024, 'Approval links must be valid between 1 and 720 hours.', 1;
    IF @ReminderHours NOT BETWEEN 0 AND 168 THROW 65024, 'Reminders: between 0 (never) and 168 hours.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'User ' + CAST(a.UserId AS NVARCHAR(10)) + N' is not an active user.'
    FROM @Approvers a
    LEFT JOIN security.Users u ON u.Id = a.UserId AND u.IsActive = 1
    WHERE (a.CanApproveInApp = 1 OR a.CanApproveByEmail = 1) AND u.Id IS NULL
    ORDER BY a.UserId;
    IF @Msg IS NOT NULL THROW 65024, @Msg, 1;

    SELECT TOP (1) @Msg = u.FullName + N' has no email address: tick "In the app" only, or add the address to the user.'
    FROM @Approvers a
    INNER JOIN security.Users u ON u.Id = a.UserId
    WHERE a.CanApproveByEmail = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NULL
    ORDER BY u.FullName;
    IF @Msg IS NOT NULL THROW 65024, @Msg, 1;

    IF @RequireApproval = 1 AND NOT EXISTS (SELECT 1 FROM @Approvers WHERE CanApproveInApp = 1 OR CanApproveByEmail = 1)
        THROW 65024, 'Choose at least one approver while purchase orders need approval.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM purchase.ApprovalSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO purchase.ApprovalSettings (Id) VALUES (1);
        ELSE IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ApprovalSettings WHERE Id = 1 AND RowVersion = @RowVersion)
            THROW 65004, 'Someone else changed the approval settings. Reload the page and try again.', 1;

        UPDATE purchase.ApprovalSettings
        SET RequireApproval = @RequireApproval, ApprovalLimitBase = @ApprovalLimitBase, AllowSelfApproval = @AllowSelfApproval,
            LinkValidHours = @LinkValidHours, ReminderHours = @ReminderHours, NotifyAppApprovers = @NotifyAppApprovers,
            EmailSupplierOnApproval = @EmailSupplierOnApproval, CopyToOwners = @CopyToOwners, CopyToEmails = @CopyToEmails,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = 1;

        DELETE o FROM purchase.OrderApprovers o
        WHERE NOT EXISTS (SELECT 1 FROM @Approvers a
                          WHERE a.UserId = o.UserId AND (a.CanApproveInApp = 1 OR a.CanApproveByEmail = 1));

        UPDATE o
        SET CanApproveInApp = a.CanApproveInApp, CanApproveByEmail = a.CanApproveByEmail,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.OrderApprovers o
        INNER JOIN @Approvers a ON a.UserId = o.UserId
        WHERE (a.CanApproveInApp = 1 OR a.CanApproveByEmail = 1)
          AND (o.CanApproveInApp <> a.CanApproveInApp OR o.CanApproveByEmail <> a.CanApproveByEmail);

        INSERT INTO purchase.OrderApprovers (UserId, CanApproveInApp, CanApproveByEmail, UpdatedBy)
        SELECT a.UserId, a.CanApproveInApp, a.CanApproveByEmail, @UserId
        FROM @Approvers a
        WHERE (a.CanApproveInApp = 1 OR a.CanApproveByEmail = 1)
          AND NOT EXISTS (SELECT 1 FROM purchase.OrderApprovers o WHERE o.UserId = a.UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_ApprovalSettings_Get;
END
GO

-- 8.3 What the signed-in user needs to know about purchase approval (buttons, menu badge).
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalSettings_ForUser
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT RequireApproval   = CAST(ISNULL(s.RequireApproval, 1) AS BIT),
           AllowSelfApproval = CAST(ISNULL(s.AllowSelfApproval, 1) AS BIT),
           ApprovalLimitBase = ISNULL(s.ApprovalLimitBase, 0),
           BaseCurrencyCode  = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1),
           CanApproveInApp   = CAST(ISNULL(ap.CanApproveInApp, 0) AS BIT),
           CanApproveByEmail = CAST(ISNULL(ap.CanApproveByEmail, 0) AS BIT),
           PendingCount      = (SELECT COUNT(*)
                                FROM purchase.PurchaseDocuments d
                                INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
                                WHERE d.Status = 5
                                  AND EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(d.Id) a
                                              WHERE a.UserId = @UserId AND a.CanApproveInApp = 1))
    FROM (SELECT One = 1) one
    LEFT JOIN purchase.ApprovalSettings s ON s.Id = 1
    OUTER APPLY (SELECT TOP (1) a.CanApproveInApp, a.CanApproveByEmail
                 FROM purchase.fn_PurchaseOrder_Approvers(NULL) a WHERE a.UserId = @UserId) ap;
END
GO

-- 8.4 Settings > Email: the row WITHOUT the password.
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Id, e.SendingEnabled, e.SmtpHost, e.SmtpPort, e.SmtpSecurity, e.SmtpUserName, e.FromAddress, e.FromName,
           e.ReplyToAddress, e.PublicBaseUrl, e.LastTestAtUtc, e.LastTestOk, e.LastTestError, e.UpdatedAtUtc, e.UpdatedBy,
           e.RowVersion,
           HasPassword   = CAST(CASE WHEN e.SmtpPasswordProtected IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           IsSaved       = CAST(CASE WHEN e.UpdatedAtUtc IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           UpdatedByName = u.FullName
    FROM messaging.EmailSettings e
    LEFT JOIN security.Users u ON u.Id = e.UpdatedBy
    WHERE e.Id = 1;
END
GO

-- 8.5 The row WITH the encrypted password: read only by the API to send.
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_GetForSending
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Id, e.SendingEnabled, e.SmtpHost, e.SmtpPort, e.SmtpSecurity, e.SmtpUserName, e.SmtpPasswordProtected,
           e.FromAddress, e.FromName, e.ReplyToAddress, e.PublicBaseUrl, e.UpdatedAtUtc, e.RowVersion
    FROM messaging.EmailSettings e
    WHERE e.Id = 1;
END
GO

-- 8.6 Saves the page. The password is kept (0), replaced by the encrypted value of the API (1) or removed (2).
-- Returns what usp_EmailSettings_Get returns.
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_Save
    @SendingEnabled        BIT,
    @SmtpHost              NVARCHAR(200) = NULL,
    @SmtpPort              INT,
    @SmtpSecurity          TINYINT,
    @SmtpUserName          NVARCHAR(256) = NULL,
    @PasswordAction        TINYINT       = 0,       -- 0 keep, 1 replace, 2 remove
    @SmtpPasswordProtected NVARCHAR(MAX) = NULL,
    @FromAddress           NVARCHAR(256) = NULL,
    @FromName              NVARCHAR(200) = NULL,
    @ReplyToAddress        NVARCHAR(256) = NULL,
    @PublicBaseUrl         NVARCHAR(300) = NULL,
    @RowVersion            BINARY(8)     = NULL,
    @UserId                INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @SendingEnabled = ISNULL(@SendingEnabled, 0),
           @PasswordAction = ISNULL(@PasswordAction, 0),
           @SmtpHost = NULLIF(LTRIM(RTRIM(@SmtpHost)), N''),
           @SmtpUserName = NULLIF(LTRIM(RTRIM(@SmtpUserName)), N''),
           @SmtpPasswordProtected = NULLIF(LTRIM(RTRIM(@SmtpPasswordProtected)), N''),
           @FromAddress = NULLIF(LTRIM(RTRIM(@FromAddress)), N''),
           @FromName = NULLIF(LTRIM(RTRIM(@FromName)), N''),
           @ReplyToAddress = NULLIF(LTRIM(RTRIM(@ReplyToAddress)), N''),
           @PublicBaseUrl = NULLIF(LTRIM(RTRIM(@PublicBaseUrl)), N'');
    WHILE RIGHT(@PublicBaseUrl, 1) = N'/'
        SET @PublicBaseUrl = LEFT(@PublicBaseUrl, DATALENGTH(@PublicBaseUrl) / 2 - 1);
    SET @PublicBaseUrl = NULLIF(@PublicBaseUrl, N'');

    IF @SendingEnabled = 1 AND (@SmtpHost IS NULL OR @FromAddress IS NULL)
        THROW 65025, 'Enter the mail server and the sender address before switching sending on.', 1;
    IF @SmtpPort IS NULL OR @SmtpPort NOT BETWEEN 1 AND 65535
        THROW 65025, 'The port must be between 1 and 65535.', 1;
    IF @SmtpSecurity IS NULL OR @SmtpSecurity NOT IN (0, 1, 2)
        THROW 65025, 'Unknown security option.', 1;
    IF @FromAddress IS NOT NULL AND (@FromAddress NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @FromAddress) > 0)
        THROW 65025, 'The sender address is not a valid email address.', 1;
    IF @ReplyToAddress IS NOT NULL AND (@ReplyToAddress NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @ReplyToAddress) > 0)
        THROW 65025, 'The reply-to address is not a valid email address.', 1;
    IF @PublicBaseUrl IS NOT NULL AND @PublicBaseUrl NOT LIKE N'http://_%' AND @PublicBaseUrl NOT LIKE N'https://_%'
        THROW 65025, 'The address of the application must start with http:// or https://.', 1;
    IF @PasswordAction NOT IN (0, 1, 2)
        THROW 65025, 'Unknown password action.', 1;
    IF @PasswordAction = 1 AND @SmtpPasswordProtected IS NULL
        THROW 65025, 'Type the new password.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO messaging.EmailSettings (Id) VALUES (1);
        ELSE IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WHERE Id = 1 AND RowVersion = @RowVersion)
            THROW 65004, 'Someone else changed the email settings. Reload the page and try again.', 1;

        UPDATE messaging.EmailSettings
        SET SendingEnabled = @SendingEnabled, SmtpHost = @SmtpHost, SmtpPort = @SmtpPort, SmtpSecurity = @SmtpSecurity,
            SmtpUserName = @SmtpUserName,
            SmtpPasswordProtected = CASE @PasswordAction WHEN 1 THEN @SmtpPasswordProtected WHEN 2 THEN NULL
                                                         ELSE SmtpPasswordProtected END,
            FromAddress = @FromAddress, FromName = @FromName, ReplyToAddress = @ReplyToAddress, PublicBaseUrl = @PublicBaseUrl,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC messaging.usp_EmailSettings_Get;
END
GO

-- 8.7 The result of "Send test email". Returns the new RowVersion: the page keeps it, so its next Save is not refused.
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_SetTestResult
    @Ok    BIT,
    @Error NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Ok IS NULL THROW 65025, 'The result of the test is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO messaging.EmailSettings (Id) VALUES (1);

        UPDATE messaging.EmailSettings
        SET LastTestAtUtc = SYSUTCDATETIME(), LastTestOk = @Ok,
            LastTestError = CASE WHEN @Ok = 1 THEN NULL ELSE LEFT(NULLIF(LTRIM(RTRIM(@Error)), N''), 1000) END
        WHERE Id = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT RowVersion FROM messaging.EmailSettings WHERE Id = 1;
END
GO

/* ================================================================== 9. Check */

SELECT RequireApproval, ApprovalLimitBase, AllowSelfApproval, LinkValidHours, ReminderHours, NotifyAppApprovers,
       EmailSupplierOnApproval, CopyToOwners, IsSaved = CAST(CASE WHEN UpdatedAtUtc IS NOT NULL THEN 1 ELSE 0 END AS BIT)
FROM purchase.ApprovalSettings;                                       -- one row

SELECT Approver = u.FullName, a.CanApproveInApp, a.CanApproveByEmail
FROM purchase.OrderApprovers a
INNER JOIN security.Users u ON u.Id = a.UserId
ORDER BY u.FullName;                                                  -- after the first run: the administrators only

SELECT SendingEnabled, IsSaved = CAST(CASE WHEN UpdatedAtUtc IS NOT NULL THEN 1 ELSE 0 END AS BIT)
FROM messaging.EmailSettings;                                         -- one row; IsSaved 0 until saved from the page

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'purchase.fn_PurchaseOrder_NeedsApproval'), (N'purchase.fn_PurchaseOrder_Approvers'),
             (N'purchase.usp_PurchaseOrder_CheckApprover'), (N'purchase.usp_PurchaseOrder_CheckToken'),
             (N'purchase.usp_PurchaseOrder_IssueLinks'), (N'purchase.usp_PurchaseOrder_ApplyDecision'),
             (N'purchase.usp_PurchaseOrder_DecisionResult'),
             (N'purchase.usp_PurchaseOrder_Approvers'), (N'purchase.usp_PurchaseOrder_RequestApproval'),
             (N'purchase.usp_PurchaseOrder_GetByToken'), (N'purchase.usp_PurchaseOrder_Decide'),
             (N'purchase.usp_PurchaseOrder_Withdraw'), (N'purchase.usp_PurchaseDocument_Post'),
             (N'purchase.usp_PurchaseOrder_DecideInApp'), (N'purchase.usp_PurchaseOrder_ApproveDirect'),
             (N'purchase.usp_PurchaseOrder_Resend'), (N'purchase.usp_PurchaseOrder_DueReminders'),
             (N'purchase.usp_PurchaseOrder_ApprovalState'), (N'purchase.usp_PurchaseOrder_ApprovalHistory'),
             (N'purchase.usp_PurchaseOrder_PendingForUser'), (N'purchase.usp_PurchaseOrder_SupplierEmailLogged'),
             (N'purchase.usp_ApprovalSettings_Get'), (N'purchase.usp_ApprovalSettings_Save'),
             (N'purchase.usp_ApprovalSettings_ForUser'),
             (N'messaging.usp_EmailSettings_Get'), (N'messaging.usp_EmailSettings_GetForSending'),
             (N'messaging.usp_EmailSettings_Save'), (N'messaging.usp_EmailSettings_SetTestResult')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 28: 2 functions, 26 procedures, none MISSING

SELECT p.Code, p.Name, p.Module, p.SortOrder, RoleName = r.Name
FROM security.Permissions p
LEFT JOIN security.RolePermissions rp ON rp.PermissionId = p.Id
LEFT JOIN security.Roles r            ON r.Id = rp.RoleId
WHERE p.Code IN (N'settings.email.manage', N'purchase.approval.manage', N'purchase.orders.approve')
ORDER BY p.Code, r.Name;                                              -- the two new ones: the system role(s) only

PRINT 'Script 42 applied: purchase approval settings (rules, approvers in the app / by email, history, reminders) and email settings.';
GO

SET NOEXEC OFF;
GO
