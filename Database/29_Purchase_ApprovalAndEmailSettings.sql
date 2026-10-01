/* =====================================================================================
   Inventory_Shipment - 29: PURCHASE ORDER APPROVAL - who approves (in the app and / or by email), the whole approval
                            cycle (reminders, send again, withdraw, history), the email settings

   1. Settings
        purchase.ApprovalSettings (one row): whether purchase orders need approval, the amount up to which an order is
        posted without approval (0 = every order needs it), whether the person who sends an order may approve it, how
        long email links stay valid, reminders, what is sent after the approval.
        purchase.OrderApprovers: the approvers, one row per user, "in the app" and / or "by email". After the first run:
        the active users of the administrator (system) roles, by email only when they have an address. Owner and
        Manager users approve once they are ticked in Settings > Purchase approval. The role permission
        purchase.orders.approve no longer decides anything (renamed "(not used)").
        messaging.EmailSettings (one row): sending on / off, mail server, sender, the address of the application used
        in the links of the emails. The SMTP password is encrypted by the API: SQL never sees it in clear.
   2. The cycle - NEW procedures; the approval procedures of script 26 are left in place, the API stops using them
        Draft --SendForApproval--> Waiting for approval (5) --DecideInApp / DecideByLink--> Approved (2 = posted, number
        assigned) or back to Draft with the reason of the rejection.
        WithdrawApproval: back to Draft. Resend / DueReminders: new emails with new links (older links stay valid until
        they expire). ApproveDirect: an in-app approver approves a draft at once. PostWithoutApproval: approval switched
        off, or an order up to the approval limit.
        Email links (purchase.PurchaseOrderApprovalLinks): personal, single use, valid N hours, stored as a SHA-256 hash
        (the token itself only travels in the email). One decision closes every open link of the order. The rights are
        checked again at the moment of the decision, whatever the channel.
        History: purchase.PurchaseOrderApprovalEvents, plus a line in the document audit for what users do.
        usp_PurchaseDocument_Post is NOT changed: a purchase order is still posted through its approval path
        (@FromApproval = 1, status 5).
   3. Orders already waiting for approval before this script can be approved in the app, withdrawn or sent again;
        their old email links (script 26) stop working once the API uses these procedures.

   Errors: 65000 validation, 65004 changed by another user, 65006 not found, 65008 supplier inactive, 65009 no lines,
           65010 invalid status, 65013 the order needs approval (posting refused), 65014 link not valid / expired / used
           (the message says what happened), 65015 nobody can approve the order, 65016 the supplier has no email address
           (only while the approved order is emailed to the supplier), 65017 not allowed to approve (in the app / by
           email); NEW 65022 approval not needed, 65023 approving one's own order is not allowed, 65024 approval
           settings, 65025 email settings (the same numbers and meanings as script 42).

   ALTERNATIVE TO SCRIPT 42: both build the same feature with different procedures. On a database where script 42 is
   applied, this script prints that it has nothing to do and changes nothing (no error).
   Written as "script 29"; in the repository 29 to 42 are taken, so give it the next free number if it is kept.

   Requires scripts 26 to 28. Idempotent: re-applied at every API start-up through Schema.sql.
   Run it with sqlcmd -I (QUOTED_IDENTIFIER ON).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.PurchaseOrderApprovals', N'U') IS NULL
   OR COL_LENGTH(N'purchase.PurchaseDocuments', N'ApprovalRequestedBy') IS NULL
   OR OBJECT_ID(N'messaging.EmailOutbox', N'U') IS NULL
   OR OBJECT_ID(N'logistics.usp_Container_PlanFromOrder', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 26 to 28 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Script 42 (or another approval script) already applied: its tables exist without the links table of this script.
-- Then this script stops quietly (no error) and changes nothing: the database already has the feature.
IF COL_LENGTH(N'purchase.PurchaseOrderApprovals', N'ClosedByEventId') IS NOT NULL
   OR (OBJECT_ID(N'purchase.ApprovalSettings', N'U') IS NOT NULL AND OBJECT_ID(N'purchase.PurchaseOrderApprovalLinks', N'U') IS NULL)
   OR (OBJECT_ID(N'messaging.EmailSettings', N'U') IS NOT NULL AND OBJECT_ID(N'purchase.PurchaseOrderApprovalLinks', N'U') IS NULL)
BEGIN
    PRINT 'Script 42 is already applied to this database: it provides the purchase order approval and the email settings,';
    PRINT 'so script 29 has nothing to do and changes nothing. This is not an error.';
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
        CONSTRAINT FK_OrderApprovers_User      FOREIGN KEY (UserId)    REFERENCES security.Users (Id) ON DELETE CASCADE,
        CONSTRAINT FK_OrderApprovers_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
END
GO

IF OBJECT_ID(N'purchase.PurchaseOrderApprovalEvents', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseOrderApprovalEvents
    (
        Id                 INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PurchaseOrderApprovalEvents PRIMARY KEY,
        PurchaseDocumentId INT            NOT NULL,
        EventType          TINYINT        NOT NULL,  -- 1 sent for approval, 2 reminder sent, 3 sent again, 4 approved,
                                                     -- 5 rejected, 6 withdrawn, 7 posted without approval,
                                                     -- 8 sent to the supplier, 9 not sent to the supplier (no address)
        Channel            TINYINT        NULL,      -- approved / rejected: 1 in the app, 2 by email
        UserId             INT            NULL,      -- who did it; NULL = the application (reminders)
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
    CREATE INDEX IX_PurchaseOrderApprovalEvents_Document
        ON purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, Id);
END
GO

IF OBJECT_ID(N'purchase.PurchaseOrderApprovalLinks', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseOrderApprovalLinks
    (
        Id                 INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PurchaseOrderApprovalLinks PRIMARY KEY,
        PurchaseDocumentId INT          NOT NULL,
        UserId             INT          NOT NULL,
        RequestEventId     INT          NOT NULL,   -- the event (sent / reminder / sent again) that created the link
        TokenHash          BINARY(32)   NOT NULL,   -- SHA-256 of the token; the token itself is only in the email
        CreatedAtUtc       DATETIME2(0) NOT NULL CONSTRAINT DF_PurchaseOrderApprovalLinks_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        ExpiresAtUtc       DATETIME2(0) NOT NULL,
        UsedAtUtc          DATETIME2(0) NULL,       -- the decision was taken with this link
        ClosedAtUtc        DATETIME2(0) NULL,       -- no longer usable: the order was decided or withdrawn
        CONSTRAINT FK_PurchaseOrderApprovalLinks_Document FOREIGN KEY (PurchaseDocumentId)
            REFERENCES purchase.PurchaseDocuments (Id) ON DELETE CASCADE,
        CONSTRAINT FK_PurchaseOrderApprovalLinks_User     FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE UNIQUE INDEX UX_PurchaseOrderApprovalLinks_TokenHash ON purchase.PurchaseOrderApprovalLinks (TokenHash);
    CREATE INDEX IX_PurchaseOrderApprovalLinks_Document ON purchase.PurchaseOrderApprovalLinks (PurchaseDocumentId, UserId);
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
        SmtpPasswordProtected NVARCHAR(MAX)  NULL,   -- encrypted by the API; never sent to the browser
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
END
GO

/* ================================================================== 2. Type */

IF TYPE_ID(N'purchase.tvp_OrderApprover') IS NULL
    CREATE TYPE purchase.tvp_OrderApprover AS TABLE
    (
        UserId            INT NOT NULL PRIMARY KEY,
        CanApproveInApp   BIT NOT NULL,
        CanApproveByEmail BIT NOT NULL
    );
GO

/* ================================================================== 3. Users as the approval sees them */

-- The view adapts itself to the security tables: the active flag, the login, and the table that links users to roles
-- (found by its foreign keys). Re-created at every start-up.
DECLARE @Active NVARCHAR(200) = N'1 = 1';
IF COL_LENGTH(N'security.Users', N'IsActive')  IS NOT NULL SET @Active = @Active + N' AND u.IsActive = 1';
IF COL_LENGTH(N'security.Users', N'IsDeleted') IS NOT NULL SET @Active = @Active + N' AND u.IsDeleted = 0';

DECLARE @Login NVARCHAR(200) =
    CASE WHEN COL_LENGTH(N'security.Users', N'UserName')  IS NOT NULL THEN N'CAST(u.UserName AS NVARCHAR(256))'
         WHEN COL_LENGTH(N'security.Users', N'Login')     IS NOT NULL THEN N'CAST(u.[Login] AS NVARCHAR(256))'
         WHEN COL_LENGTH(N'security.Users', N'LoginName') IS NOT NULL THEN N'CAST(u.LoginName AS NVARCHAR(256))'
         ELSE N'CAST(NULL AS NVARCHAR(256))' END;

DECLARE @LinkTable NVARCHAR(300), @LinkUser SYSNAME, @LinkRole SYSNAME;

SELECT TOP (1) @LinkTable = QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name),
               @LinkUser  = cu.name,
               @LinkRole  = cr.name
FROM sys.tables t
INNER JOIN sys.foreign_key_columns fu ON fu.parent_object_id = t.object_id AND fu.referenced_object_id = OBJECT_ID(N'security.Users')
INNER JOIN sys.columns cu             ON cu.object_id = t.object_id AND cu.column_id = fu.parent_column_id
INNER JOIN sys.foreign_key_columns fr ON fr.parent_object_id = t.object_id AND fr.referenced_object_id = OBJECT_ID(N'security.Roles')
INNER JOIN sys.columns cr             ON cr.object_id = t.object_id AND cr.column_id = fr.parent_column_id
WHERE t.object_id <> OBJECT_ID(N'security.Users')
  AND (t.name LIKE N'%UserRole%' OR (cu.name = N'UserId' AND cr.name = N'RoleId'))
ORDER BY CASE WHEN t.name LIKE N'%UserRole%' THEN 0 ELSE 1 END, CASE WHEN cu.name = N'UserId' THEN 0 ELSE 1 END, t.name;

IF @LinkTable IS NULL AND OBJECT_ID(N'security.UserRoles', N'U') IS NOT NULL
   AND COL_LENGTH(N'security.UserRoles', N'UserId') IS NOT NULL AND COL_LENGTH(N'security.UserRoles', N'RoleId') IS NOT NULL
    SELECT @LinkTable = N'[security].[UserRoles]', @LinkUser = N'UserId', @LinkRole = N'RoleId';

DECLARE @RoleSource NVARCHAR(600) =
    CASE WHEN @LinkTable IS NOT NULL
             THEN N'FROM ' + @LinkTable + N' ur INNER JOIN security.Roles r ON r.Id = ur.' + QUOTENAME(@LinkRole)
                  + N' WHERE ur.' + QUOTENAME(@LinkUser) + N' = u.Id'
         WHEN COL_LENGTH(N'security.Users', N'RoleId') IS NOT NULL
             THEN N'FROM security.Roles r WHERE r.Id = u.RoleId'
    END;

DECLARE @Sql NVARCHAR(MAX) = N'CREATE OR ALTER VIEW purchase.vw_ApprovalUsers
AS
SELECT UserId          = u.Id,
       FullName        = CAST(u.FullName AS NVARCHAR(200)),
       UserName        = ' + @Login + N',
       Email           = CAST(NULLIF(LTRIM(RTRIM(u.Email)), N'''') AS NVARCHAR(256)),
       IsActive        = CAST(CASE WHEN ' + @Active + N' THEN 1 ELSE 0 END AS BIT),
       IsAdministrator = CAST(' + CASE WHEN @RoleSource IS NULL THEN N'0'
                                       ELSE N'CASE WHEN EXISTS (SELECT 1 ' + @RoleSource + N' AND r.IsSystem = 1) THEN 1 ELSE 0 END' END
                         + N' AS BIT),
       Roles           = ' + CASE WHEN @RoleSource IS NULL THEN N'CAST(NULL AS NVARCHAR(1000))'
                                  ELSE N'CAST((SELECT STRING_AGG(CAST(r.Name AS NVARCHAR(MAX)), N'', '') WITHIN GROUP (ORDER BY r.Name) '
                                       + @RoleSource + N') AS NVARCHAR(1000))' END + N'
FROM security.Users u;';

EXEC sys.sp_executesql @Sql;

PRINT N'Roles of the users read from: '
      + COALESCE(@LinkTable, CASE WHEN COL_LENGTH(N'security.Users', N'RoleId') IS NOT NULL THEN N'security.Users.RoleId' END,
                 N'nowhere - no administrator can be recognised');
GO

/* ================================================================== 4. Permissions */

DECLARE @CfgModule NVARCHAR(100) = ISNULL((SELECT TOP (1) Module FROM security.Permissions WHERE Code = N'messaging.emails.view'), N'Configuration');
DECLARE @PurModule NVARCHAR(100) = ISNULL((SELECT TOP (1) Module FROM security.Permissions WHERE Code = N'purchase.orders.approve'), N'Purchasing');
DECLARE @CfgSort INT = ISNULL((SELECT TOP (1) SortOrder FROM security.Permissions WHERE Code = N'messaging.emails.view'), 920) + 5;
DECLARE @PurSort INT = ISNULL((SELECT TOP (1) SortOrder FROM security.Permissions WHERE Code = N'purchase.orders.approve'), 1050) + 5;

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'settings.email.manage',    N'Manage Email Settings',             @CfgModule,
         N'Set the mail server and the sender of the emails the application sends.', @CfgSort),
        (N'purchase.approval.manage', N'Manage Purchase Approval Settings', @PurModule,
         N'Choose who approves purchase orders, in the app or by email.',            @PurSort)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code IN (N'settings.email.manage', N'purchase.approval.manage')
  AND r.IsSystem = 1
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);

UPDATE security.Permissions
SET Name = N'Approve Purchase Orders (not used)',
    Description = N'No effect: approvers are chosen in Settings > Purchase approval.'
WHERE Code = N'purchase.orders.approve'
  AND (Name <> N'Approve Purchase Orders (not used)' OR Description IS NULL
       OR Description <> N'No effect: approvers are chosen in Settings > Purchase approval.');
GO

/* ================================================================== 5. First run: settings, approvers, email settings */

IF NOT EXISTS (SELECT 1 FROM purchase.ApprovalSettings)
BEGIN
    INSERT INTO purchase.ApprovalSettings (Id) VALUES (1);

    -- The approvers: the active administrators, by email only when they have an address.
    INSERT INTO purchase.OrderApprovers (UserId, CanApproveInApp, CanApproveByEmail)
    SELECT v.UserId, 1, CASE WHEN v.Email IS NULL THEN 0 ELSE 1 END
    FROM purchase.vw_ApprovalUsers v
    WHERE v.IsActive = 1 AND v.IsAdministrator = 1;

    -- No administrator recognised (no user-role table found): the user who signs in as "admin".
    IF NOT EXISTS (SELECT 1 FROM purchase.OrderApprovers)
        INSERT INTO purchase.OrderApprovers (UserId, CanApproveInApp, CanApproveByEmail)
        SELECT TOP (1) v.UserId, 1, CASE WHEN v.Email IS NULL THEN 0 ELSE 1 END
        FROM purchase.vw_ApprovalUsers v
        WHERE v.IsActive = 1 AND v.UserName = N'admin'
        ORDER BY v.UserId;
END

IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings)
    INSERT INTO messaging.EmailSettings (Id) VALUES (1);
GO

/* ================================================================== 6. Functions */

-- 1 when the order must be approved before it is posted: approval switched on and the order above the limit
-- (limit 0 = every order). No settings row = approval needed.
CREATE OR ALTER FUNCTION purchase.fn_PurchaseOrder_NeedsApproval (@PurchaseDocumentId INT)
RETURNS BIT
AS
BEGIN
    DECLARE @Require BIT, @Limit DECIMAL(19, 4), @TotalBase DECIMAL(19, 4);

    SELECT @Require = RequireApproval, @Limit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
    IF @Require IS NULL RETURN 1;
    IF @Require = 0 RETURN 0;
    IF @Limit = 0 RETURN 1;

    SELECT @TotalBase = ISNULL(d.TotalAmountBase, d.TotalAmount / NULLIF(d.ExchangeRate, 0))
    FROM purchase.PurchaseDocuments d
    WHERE d.Id = @PurchaseDocumentId;

    RETURN CASE WHEN @TotalBase IS NOT NULL AND @TotalBase <= @Limit THEN 0 ELSE 1 END;
END
GO

-- The approvers of an order (NULL = of any order): active users of purchase.OrderApprovers. "By email" counts only
-- for a user who has an email address. When the person who sends an order may not approve it, its creator and the
-- user who sent it for approval are left out.
CREATE OR ALTER FUNCTION purchase.fn_PurchaseOrder_Approvers (@PurchaseDocumentId INT)
RETURNS TABLE
AS
RETURN
    SELECT a.UserId, v.FullName, v.Email,
           CanApproveInApp   = a.CanApproveInApp,
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND v.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM purchase.OrderApprovers a
    INNER JOIN purchase.vw_ApprovalUsers v ON v.UserId = a.UserId AND v.IsActive = 1
    OUTER APPLY (SELECT TOP (1) x.AllowSelfApproval FROM purchase.ApprovalSettings x WHERE x.Id = 1) st
    OUTER APPLY (SELECT TOP (1) pd.CreatedBy, pd.ApprovalRequestedBy
                 FROM purchase.PurchaseDocuments pd WHERE pd.Id = @PurchaseDocumentId) d
    WHERE (a.CanApproveInApp = 1 OR (a.CanApproveByEmail = 1 AND v.Email IS NOT NULL))
      AND (ISNULL(st.AllowSelfApproval, 1) = 1
           OR (a.UserId <> ISNULL(d.CreatedBy, 0) AND a.UserId <> ISNULL(d.ApprovalRequestedBy, 0)));
GO

-- Why an email link can no longer be used; NULL = it can be used.
CREATE OR ALTER FUNCTION purchase.fn_ApprovalLink_Problem (@LinkId INT)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @DocId INT, @RequestEventId INT, @Expires DATETIME2(0), @Used DATETIME2(0), @Closed DATETIME2(0), @Status INT;

    SELECT @DocId = l.PurchaseDocumentId, @RequestEventId = l.RequestEventId, @Expires = l.ExpiresAtUtc,
           @Used = l.UsedAtUtc, @Closed = l.ClosedAtUtc
    FROM purchase.PurchaseOrderApprovalLinks l
    WHERE l.Id = @LinkId;

    IF @DocId IS NULL RETURN N'This approval link is not valid.';

    -- the first decision after the link was sent is the one that closed it
    DECLARE @Type TINYINT, @At DATETIME2(0), @By NVARCHAR(200);
    SELECT TOP (1) @Type = e.EventType, @At = e.AtUtc, @By = u.FullName
    FROM purchase.PurchaseOrderApprovalEvents e
    LEFT JOIN security.Users u ON u.Id = e.UserId
    WHERE e.PurchaseDocumentId = @DocId AND e.Id > @RequestEventId AND e.EventType IN (4, 5, 6)
    ORDER BY e.Id;

    IF @Type = 4 RETURN N'This order was already approved by ' + ISNULL(@By, N'another approver') + N' on '
                        + CONVERT(NVARCHAR(11), @At, 106) + N'.';
    IF @Type = 5 RETURN N'This order was rejected by ' + ISNULL(@By, N'another approver') + N' on '
                        + CONVERT(NVARCHAR(11), @At, 106) + N'.';
    IF @Type = 6 RETURN N'This request was withdrawn on ' + CONVERT(NVARCHAR(11), @At, 106) + N'.';
    IF @Used IS NOT NULL OR @Closed IS NOT NULL RETURN N'This link was already used.';
    IF @Expires < SYSUTCDATETIME() RETURN N'This link has expired: ask for a new email, or approve in the application.';

    SELECT @Status = d.Status FROM purchase.PurchaseDocuments d WHERE d.Id = @DocId;
    IF ISNULL(@Status, 0) <> 5 RETURN N'This order is no longer waiting for approval.';

    RETURN NULL;
END
GO

/* ================================================================== 7. Internal procedures */

-- Internal: one line in the audit of the document (what users do; the application's reminders are not written).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_WriteAudit
    @PurchaseDocumentId INT,
    @Action             NVARCHAR(100),
    @Details            NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @UserId IS NULL RETURN;

    -- COL_LENGTH is in bytes (2 per character), -1 for MAX
    DECLARE @A INT = COL_LENGTH(N'purchase.PurchaseDocumentAudit', N'Action'),
            @D INT = COL_LENGTH(N'purchase.PurchaseDocumentAudit', N'Details');

    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@PurchaseDocumentId,
            CASE WHEN @A > 0 THEN LEFT(@Action, @A / 2) ELSE @Action END,
            CASE WHEN @D > 0 THEN LEFT(ISNULL(@Details, N''), @D / 2) ELSE ISNULL(@Details, N'') END,
            @UserId);
END
GO

-- Internal, inside the caller's transaction (the order locked by the caller): sends the request of an order to its
-- approvers. Writes the event, one personal link per by-email approver, and one row per approver into
-- #ApprovalRequest, created by the caller. THROW 65015 when nobody can approve the order.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_IssueRequest
    @PurchaseDocumentId INT,
    @EventType          TINYINT,          -- 1 sent for approval, 2 reminder, 3 sent again
    @UserId             INT = NULL        -- NULL = the application (reminders)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ValidHours INT, @NotifyApp BIT;
    SELECT @ValidHours = LinkValidHours, @NotifyApp = NotifyAppApprovers FROM purchase.ApprovalSettings WHERE Id = 1;
    SELECT @ValidHours = ISNULL(@ValidHours, 72), @NotifyApp = ISNULL(@NotifyApp, 1);

    DECLARE @Approvers TABLE
    (
        UserId            INT           NOT NULL PRIMARY KEY,
        FullName          NVARCHAR(200) NULL,
        Email             NVARCHAR(256) NULL,
        CanApproveInApp   BIT           NOT NULL,
        CanApproveByEmail BIT           NOT NULL,
        Token             VARCHAR(64)   NULL
    );

    INSERT INTO @Approvers (UserId, FullName, Email, CanApproveInApp, CanApproveByEmail)
    SELECT a.UserId, a.FullName, a.Email, a.CanApproveInApp, a.CanApproveByEmail
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a;

    IF NOT EXISTS (SELECT 1 FROM @Approvers)
        THROW 65015, 'Nobody can approve this order: choose the approvers in Settings > Purchase approval.', 1;

    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Expires DATETIME2(0) = DATEADD(HOUR, @ValidHours, @Now);
    DECLARE @Recipients NVARCHAR(1000) =
        LEFT((SELECT STRING_AGG(CAST(ISNULL(a.FullName, N'User ' + CAST(a.UserId AS NVARCHAR(10)))
                                     + CASE WHEN a.CanApproveInApp = 1 AND a.CanApproveByEmail = 1 THEN N' (in the app and by email)'
                                            WHEN a.CanApproveByEmail = 1 THEN N' (by email)'
                                            ELSE N' (in the app)' END AS NVARCHAR(MAX)), N', ')
                     WITHIN GROUP (ORDER BY a.FullName)
              FROM @Approvers a), 1000);

    INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Recipients, AtUtc)
    VALUES (@PurchaseDocumentId, @EventType, @UserId, @Recipients, @Now);
    DECLARE @EventId INT = SCOPE_IDENTITY();

    -- one personal token per by-email approver: 32 random bytes, only the SHA-256 of the text is kept
    DECLARE @U INT = 0, @Token VARCHAR(64);
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @U = UserId FROM @Approvers WHERE CanApproveByEmail = 1 AND UserId > @U ORDER BY UserId;
        IF @@ROWCOUNT = 0 BREAK;

        SET @Token = LOWER(CONVERT(VARCHAR(64), CRYPT_GEN_RANDOM(32), 2));
        INSERT INTO purchase.PurchaseOrderApprovalLinks (PurchaseDocumentId, UserId, RequestEventId, TokenHash, CreatedAtUtc, ExpiresAtUtc)
        VALUES (@PurchaseDocumentId, @U, @EventId, HASHBYTES('SHA2_256', @Token), @Now, @Expires);
        UPDATE @Approvers SET Token = @Token WHERE UserId = @U;
    END

    INSERT INTO #ApprovalRequest (PurchaseDocumentId, EventType, UserId, FullName, Email, Channel, CanApproveInApp,
                                  CanApproveByEmail, SendEmail, Token, ExpiresAtUtc)
    SELECT @PurchaseDocumentId, @EventType, a.UserId, a.FullName, a.Email,
           CASE WHEN a.CanApproveByEmail = 1 THEN 'Email' ELSE 'App' END,
           a.CanApproveInApp, a.CanApproveByEmail,
           CAST(CASE WHEN a.CanApproveByEmail = 1 THEN 1
                     WHEN a.Email IS NOT NULL AND @NotifyApp = 1 THEN 1
                     ELSE 0 END AS BIT),
           a.Token,
           CASE WHEN a.CanApproveByEmail = 1 THEN @Expires END
    FROM @Approvers a;
END
GO

-- Internal: the rows of a request for the API (one per approver), read from #ApprovalRequest.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_RequestRows
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.PurchaseDocumentId, r.EventType, r.UserId, r.FullName, r.Email, r.Channel, r.CanApproveInApp,
           r.CanApproveByEmail, r.SendEmail, r.Token, r.ExpiresAtUtc,
           d.DocumentNumber, RequestedBy = d.ApprovalRequestedBy, RequestedByName = ru.FullName,
           RequestedAtUtc = d.ApprovalRequestedAtUtc, d.RowVersion
    FROM #ApprovalRequest r
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = r.PurchaseDocumentId
    LEFT  JOIN security.Users ru           ON ru.Id = d.ApprovalRequestedBy
    ORDER BY r.PurchaseDocumentId, r.FullName;
END
GO

-- Internal: the user of an email link may still decide on the order (THROW 65023 / 65017 otherwise).
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalLink_CheckRights
    @PurchaseDocumentId INT,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL((SELECT AllowSelfApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 0
       AND EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                   WHERE d.Id = @PurchaseDocumentId AND (d.CreatedBy = @UserId OR d.ApprovalRequestedBy = @UserId))
        THROW 65023, 'You cannot approve an order that you created or sent for approval.', 1;

    IF NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
                   WHERE a.UserId = @UserId AND a.CanApproveByEmail = 1)
        THROW 65017, 'You can no longer approve purchase orders by email.', 1;
END
GO

-- Internal, inside the caller's transaction (the order waiting for approval and locked by the caller): approves
-- (= posts through usp_PurchaseDocument_Post, number assigned) or rejects (back to draft with the reason).
-- Closes every open link of the order, writes the event and the audit.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApplyDecision
    @PurchaseDocumentId INT,
    @Approve            BIT,
    @Reason             NVARCHAR(500) = NULL,
    @UserId             INT,
    @Channel            TINYINT,                 -- 1 in the app, 2 by email
    @Note               NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @How NVARCHAR(20) = CASE WHEN @Channel = 2 THEN N'by email' ELSE N'in the app' END;

    IF @Approve = 1
    BEGIN
        EXEC purchase.usp_PurchaseDocument_Post @Id = @PurchaseDocumentId, @UserId = @UserId, @FromApproval = 1;

        UPDATE purchase.PurchaseDocuments
        SET ApprovedAtUtc = @Now, ApprovedBy = @UserId, RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL
        WHERE Id = @PurchaseDocumentId;
    END
    ELSE
    BEGIN
        DECLARE @Max INT = COL_LENGTH(N'purchase.PurchaseDocuments', N'RejectReason');
        UPDATE purchase.PurchaseDocuments
        SET Status = 1, RejectedAtUtc = @Now, RejectedBy = @UserId,
            RejectReason = CASE WHEN @Max > 0 THEN LEFT(@Reason, @Max / 2) ELSE @Reason END,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @PurchaseDocumentId;
    END

    UPDATE purchase.PurchaseOrderApprovalLinks
    SET ClosedAtUtc = @Now
    WHERE PurchaseDocumentId = @PurchaseDocumentId AND ClosedAtUtc IS NULL;

    INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, Channel, UserId, Reason, Note, AtUtc)
    VALUES (@PurchaseDocumentId, CASE WHEN @Approve = 1 THEN 4 ELSE 5 END, @Channel, @UserId,
            CASE WHEN @Approve = 0 THEN @Reason END, @Note, @Now);

    DECLARE @Action NVARCHAR(100) = CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END;
    DECLARE @Details NVARCHAR(1000) =
        CASE WHEN @Approve = 1 THEN N'Approved ' + @How + ISNULL(N' - ' + @Note, N'')
             ELSE N'Rejected ' + @How + N': ' + ISNULL(@Reason, N'') END;
    EXEC purchase.usp_PurchaseOrder_WriteAudit @PurchaseDocumentId = @PurchaseDocumentId, @Action = @Action,
         @Details = @Details, @UserId = @UserId;
END
GO

-- Internal: the result of a decision or of a posting without approval, for the emails that follow it
-- (supplier, copies, requester).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DecisionResult
    @PurchaseDocumentId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PurchaseDocumentId = d.Id, d.DocumentNumber, d.Status,
           Approved        = CAST(CASE WHEN d.Status = 2 THEN 1 ELSE 0 END AS BIT),
           e.EventType,
           EventName       = CASE e.EventType WHEN 4 THEN N'Approved' WHEN 5 THEN N'Rejected' WHEN 7 THEN N'Posted without approval' END,
           e.Channel,
           ChannelName     = CASE e.Channel WHEN 1 THEN N'In the app' WHEN 2 THEN N'By email' END,
           DecidedBy       = e.UserId, DecidedByName = du.FullName, DecidedByEmail = du.Email, DecidedAtUtc = e.AtUtc,
           e.Reason, e.Note,
           RequestedBy     = d.ApprovalRequestedBy, RequestedByName = ru.FullName, RequestedByEmail = ru.Email,
           d.CreatedBy, CreatedByName = cu.FullName, CreatedByEmail = cu.Email,
           d.SupplierId, SupplierName = sp.PartyName, SupplierEmail = NULLIF(LTRIM(RTRIM(sp.Email)), N''),
           EmailSupplierOnApproval = ISNULL(st.EmailSupplierOnApproval, CAST(1 AS BIT)),
           CopyToOwners    = ISNULL(st.CopyToOwners, CAST(1 AS BIT)),
           st.CopyToEmails,
           d.TotalAmount, c.CurrencyCode, d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp   ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    OUTER APPLY (SELECT TOP (1) x.EventType, x.Channel, x.UserId, x.AtUtc, x.Reason, x.Note
                 FROM purchase.PurchaseOrderApprovalEvents x
                 WHERE x.PurchaseDocumentId = d.Id AND x.EventType IN (4, 5, 7)
                 ORDER BY x.Id DESC) e
    OUTER APPLY (SELECT TOP (1) s.EmailSupplierOnApproval, s.CopyToOwners, s.CopyToEmails
                 FROM purchase.ApprovalSettings s WHERE s.Id = 1) st
    LEFT  JOIN purchase.vw_ApprovalUsers du ON du.UserId = e.UserId
    LEFT  JOIN purchase.vw_ApprovalUsers ru ON ru.UserId = d.ApprovalRequestedBy
    LEFT  JOIN purchase.vw_ApprovalUsers cu ON cu.UserId = d.CreatedBy
    WHERE d.Id = @PurchaseDocumentId;
END
GO

/* ================================================================== 8. The approval cycle */

-- Sends a DRAFT purchase order for approval: status 5 (locked), one personal email link per by-email approver.
-- Returns one row per approver (usp_PurchaseOrder_RequestRows): the API emails the rows with SendEmail = 1
-- (Channel 'Email': the approval email with its link; 'App': a notice with a link to the order).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_SendForApproval
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #ApprovalRequest
    (
        PurchaseDocumentId INT           NOT NULL,
        EventType          TINYINT       NOT NULL,
        UserId             INT           NOT NULL,
        FullName           NVARCHAR(200) NULL,
        Email              NVARCHAR(256) NULL,
        Channel            VARCHAR(5)    NOT NULL,
        CanApproveInApp    BIT           NOT NULL,
        CanApproveByEmail  BIT           NOT NULL,
        SendEmail          BIT           NOT NULL,
        Token              VARCHAR(64)   NULL,
        ExpiresAtUtc       DATETIME2(0)  NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status INT, @TypeCode NVARCHAR(20), @SupplierId INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @SupplierId = d.SupplierId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' THROW 65000, 'Only purchase orders are sent for approval.', 1;
        IF @Status <> 1 THROW 65010, 'Only a draft purchase order can be sent for approval.', 1;
        IF @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @PurchaseDocumentId)
            THROW 65009, 'The order has no lines. Add at least one item before sending it for approval.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;
        IF purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId) = 0
            THROW 65022, 'This order does not need approval: post it.', 1;
        IF ISNULL((SELECT EmailSupplierOnApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 1
           AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL)
            THROW 65016, 'The supplier has no email address: add it to the supplier, or switch off "Email the approved order to the supplier".', 1;

        DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = @Now, ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @PurchaseDocumentId;

        EXEC purchase.usp_PurchaseOrder_IssueRequest @PurchaseDocumentId = @PurchaseDocumentId, @EventType = 1, @UserId = @UserId;

        DECLARE @Details NVARCHAR(1000) =
            N'To ' + (SELECT TOP (1) e.Recipients FROM purchase.PurchaseOrderApprovalEvents e
                      WHERE e.PurchaseDocumentId = @PurchaseDocumentId ORDER BY e.Id DESC);
        EXEC purchase.usp_PurchaseOrder_WriteAudit @PurchaseDocumentId = @PurchaseDocumentId, @Action = N'Sent for approval',
             @Details = @Details, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_RequestRows;
END
GO

-- Sends an order that waits for approval again ("Send again"): new email links; the older ones stay valid until they
-- expire. Same result as usp_PurchaseOrder_SendForApproval.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Resend
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #ApprovalRequest
    (
        PurchaseDocumentId INT           NOT NULL,
        EventType          TINYINT       NOT NULL,
        UserId             INT           NOT NULL,
        FullName           NVARCHAR(200) NULL,
        Email              NVARCHAR(256) NULL,
        Channel            VARCHAR(5)    NOT NULL,
        CanApproveInApp    BIT           NOT NULL,
        CanApproveByEmail  BIT           NOT NULL,
        SendEmail          BIT           NOT NULL,
        Token              VARCHAR(64)   NULL,
        ExpiresAtUtc       DATETIME2(0)  NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status INT, @TypeCode NVARCHAR(20);
        SELECT @Status = d.Status, @TypeCode = dt.Code
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be sent again.', 1;
        IF @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        EXEC purchase.usp_PurchaseOrder_IssueRequest @PurchaseDocumentId = @PurchaseDocumentId, @EventType = 3, @UserId = @UserId;

        DECLARE @Details NVARCHAR(1000) =
            N'To ' + (SELECT TOP (1) e.Recipients FROM purchase.PurchaseOrderApprovalEvents e
                      WHERE e.PurchaseDocumentId = @PurchaseDocumentId ORDER BY e.Id DESC);
        EXEC purchase.usp_PurchaseOrder_WriteAudit @PurchaseDocumentId = @PurchaseDocumentId, @Action = N'Sent again for approval',
             @Details = @Details, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_RequestRows;
END
GO

-- Reminders, called by the API every few minutes: every order waiting for approval whose last email is older than
-- ReminderHours (0 = never) gets new emails with new links. One transaction per order; an order that fails is skipped.
-- Returns the rows of every reminded order (same columns as usp_PurchaseOrder_SendForApproval, EventType 2).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DueReminders
    @MaxOrders INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #ApprovalRequest
    (
        PurchaseDocumentId INT           NOT NULL,
        EventType          TINYINT       NOT NULL,
        UserId             INT           NOT NULL,
        FullName           NVARCHAR(200) NULL,
        Email              NVARCHAR(256) NULL,
        Channel            VARCHAR(5)    NOT NULL,
        CanApproveInApp    BIT           NOT NULL,
        CanApproveByEmail  BIT           NOT NULL,
        SendEmail          BIT           NOT NULL,
        Token              VARCHAR(64)   NULL,
        ExpiresAtUtc       DATETIME2(0)  NULL
    );

    DECLARE @Hours INT = (SELECT ReminderHours FROM purchase.ApprovalSettings WHERE Id = 1);
    SET @MaxOrders = ISNULL(@MaxOrders, 50);

    IF ISNULL(@Hours, 0) > 0
    BEGIN
        DECLARE @Due TABLE (Seq INT IDENTITY(1, 1) NOT NULL PRIMARY KEY, Id INT NOT NULL);

        INSERT INTO @Due (Id)
        SELECT TOP (@MaxOrders) d.Id
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
        CROSS APPLY (SELECT TOP (1) a.UserId FROM purchase.fn_PurchaseOrder_Approvers(d.Id) a) ap
        OUTER APPLY (SELECT LastSent = MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
                     WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)) x
        WHERE d.Status = 5
          AND COALESCE(x.LastSent, d.ApprovalRequestedAtUtc, d.UpdatedAtUtc) < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
        ORDER BY COALESCE(x.LastSent, d.ApprovalRequestedAtUtc, d.UpdatedAtUtc), d.Id;

        DECLARE @Seq INT = 0, @Id INT;
        WHILE 1 = 1
        BEGIN
            SELECT TOP (1) @Seq = Seq, @Id = Id FROM @Due WHERE Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;

            BEGIN TRY
                BEGIN TRANSACTION;
                IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id AND Status = 5)
                    EXEC purchase.usp_PurchaseOrder_IssueRequest @PurchaseDocumentId = @Id, @EventType = 2, @UserId = NULL;
                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;      -- this order is skipped, the others go on
            END CATCH
        END
    END

    EXEC purchase.usp_PurchaseOrder_RequestRows;
END
GO

-- Withdraws the request of an order waiting for approval: back to draft (editable), its email links stop working.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_WithdrawApproval
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8)     = NULL,
    @UserId             INT,
    @Reason             NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status INT, @TypeCode NVARCHAR(20);
        SELECT @Status = d.Status, @TypeCode = dt.Code
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be withdrawn.', 1;
        IF @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
        UPDATE purchase.PurchaseDocuments SET Status = 1, UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @PurchaseDocumentId;

        UPDATE purchase.PurchaseOrderApprovalLinks
        SET ClosedAtUtc = @Now
        WHERE PurchaseDocumentId = @PurchaseDocumentId AND ClosedAtUtc IS NULL;

        INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Reason, AtUtc)
        VALUES (@PurchaseDocumentId, 6, @UserId, @Reason, @Now);

        DECLARE @Details NVARCHAR(1000) = N'Approval request withdrawn' + ISNULL(N': ' + @Reason, N'');
        EXEC purchase.usp_PurchaseOrder_WriteAudit @PurchaseDocumentId = @PurchaseDocumentId, @Action = N'Withdrawn',
             @Details = @Details, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PurchaseDocumentId = d.Id, d.Status, d.RowVersion
    FROM purchase.PurchaseDocuments d
    WHERE d.Id = @PurchaseDocumentId;
END
GO

-- Approves or rejects in the application an order waiting for approval. The user must be an in-app approver of the
-- order (65017); a rejection needs a reason. Returns usp_PurchaseOrder_DecisionResult.
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

    IF @Approve IS NULL THROW 65000, 'Choose to approve or to reject the order.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status INT, @TypeCode NVARCHAR(20), @CreatedBy INT, @RequestedBy INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @CreatedBy = d.CreatedBy, @RequestedBy = d.ApprovalRequestedBy
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved or rejected.', 1;
        IF @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF ISNULL((SELECT AllowSelfApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 0
           AND @UserId IN (ISNULL(@CreatedBy, 0), ISNULL(@RequestedBy, 0))
            THROW 65023, 'You cannot approve an order that you created or sent for approval.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
                       WHERE a.UserId = @UserId AND a.CanApproveInApp = 1)
            THROW 65017, 'You are not allowed to approve or reject purchase orders in the app.', 1;
        IF @Approve = 0 AND @Reason IS NULL THROW 65000, 'Type the reason of the rejection.', 1;

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @PurchaseDocumentId, @Approve = @Approve,
             @Reason = @Reason, @UserId = @UserId, @Channel = 1, @Note = NULL;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @PurchaseDocumentId;
END
GO

-- "Approve & post" / "Create & approve": an in-app approver approves a DRAFT at once, without sending a request
-- (only when the person who sends an order may approve it). Returns usp_PurchaseOrder_DecisionResult.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApproveDirect
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status INT, @TypeCode NVARCHAR(20), @SupplierId INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @SupplierId = d.SupplierId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' THROW 65000, 'Only purchase orders are approved.', 1;
        IF @Status <> 1 THROW 65010, 'Only a draft purchase order can be approved directly.', 1;
        IF @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @PurchaseDocumentId)
            THROW 65009, 'The order has no lines. Add at least one item before approving it.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;
        IF purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId) = 0
            THROW 65022, 'This order does not need approval: post it.', 1;
        IF ISNULL((SELECT EmailSupplierOnApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 1
           AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL)
            THROW 65016, 'The supplier has no email address: add it to the supplier, or switch off "Email the approved order to the supplier".', 1;
        IF ISNULL((SELECT AllowSelfApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 0
            THROW 65023, 'Approving your own order is not allowed: send it for approval.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.OrderApprovers a
                       INNER JOIN purchase.vw_ApprovalUsers v ON v.UserId = a.UserId AND v.IsActive = 1
                       WHERE a.UserId = @UserId AND a.CanApproveInApp = 1)
            THROW 65017, 'You are not allowed to approve purchase orders in the app.', 1;

        -- the approval posts the order from status 5, like any approval
        DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = @Now, ApprovalRequestedBy = @UserId, UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @PurchaseDocumentId;

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @PurchaseDocumentId, @Approve = 1, @Reason = NULL,
             @UserId = @UserId, @Channel = 1, @Note = N'Approved directly, without a request';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @PurchaseDocumentId;
END
GO

-- Posts a DRAFT purchase order that does not need approval (approval switched off, or up to the approval limit).
-- 65013 when it needs approval. Returns usp_PurchaseOrder_DecisionResult (the API then emails the supplier).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_PostWithoutApproval
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status INT, @TypeCode NVARCHAR(20);
        SELECT @Status = d.Status, @TypeCode = dt.Code
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' THROW 65000, 'Only purchase orders are posted this way.', 1;
        IF @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId) = 1
            THROW 65013, 'This order needs approval: send it for approval.', 1;

        DECLARE @Require BIT, @Limit DECIMAL(19, 4), @Base NVARCHAR(10);
        SELECT @Require = RequireApproval, @Limit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
        SELECT TOP (1) @Base = CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1 ORDER BY Id;

        DECLARE @Note NVARCHAR(200) =
            CASE WHEN ISNULL(@Require, 1) = 0 THEN N'Approval not required'
                 ELSE N'Under the approval limit of ' + FORMAT(@Limit, N'N2', N'en-US') + ISNULL(N' ' + @Base, N'') END;
        DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();

        -- usp_PurchaseDocument_Post posts a purchase order only through its approval path (status 5, @FromApproval = 1)
        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = @Now, ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL
        WHERE Id = @PurchaseDocumentId;

        EXEC purchase.usp_PurchaseDocument_Post @Id = @PurchaseDocumentId, @UserId = @UserId, @FromApproval = 1;

        UPDATE purchase.PurchaseDocuments SET ApprovedAtUtc = @Now, ApprovedBy = @UserId WHERE Id = @PurchaseDocumentId;

        INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Note, AtUtc)
        VALUES (@PurchaseDocumentId, 7, @UserId, @Note, @Now);
        EXEC purchase.usp_PurchaseOrder_WriteAudit @PurchaseDocumentId = @PurchaseDocumentId, @Action = N'Posted without approval',
             @Details = @Note, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @PurchaseDocumentId;
END
GO

-- The approval page opened from an email (no sign-in). Opening it decides nothing.
-- 65014 / 65023 / 65017 with a message that says why the link can no longer be used.
-- 2 result sets: the order (with the approver of the link), its lines.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_GetByLink
    @Token NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @T VARCHAR(64) = CASE WHEN LEN(LTRIM(RTRIM(@Token))) = 64 THEN LOWER(LTRIM(RTRIM(@Token))) END;
    DECLARE @LinkId INT, @DocId INT, @ApproverId INT, @Expires DATETIME2(0), @Problem NVARCHAR(300);

    SELECT @LinkId = l.Id, @DocId = l.PurchaseDocumentId, @ApproverId = l.UserId, @Expires = l.ExpiresAtUtc
    FROM purchase.PurchaseOrderApprovalLinks l
    WHERE l.TokenHash = HASHBYTES('SHA2_256', @T);

    IF @LinkId IS NULL THROW 65014, 'This approval link is not valid.', 1;
    SET @Problem = purchase.fn_ApprovalLink_Problem(@LinkId);
    IF @Problem IS NOT NULL THROW 65014, @Problem, 1;
    EXEC purchase.usp_ApprovalLink_CheckRights @PurchaseDocumentId = @DocId, @UserId = @ApproverId;

    SELECT PurchaseDocumentId = d.Id, d.DocumentNumber, d.Status, d.DocumentDate, d.ExpectedDate,
           SupplierCode = sp.PartyCode, SupplierName = sp.PartyName, d.SupplierReference,
           c.CurrencyCode, d.TotalAmount,
           TotalBase = ISNULL(d.TotalAmountBase, d.TotalAmount / NULLIF(d.ExchangeRate, 0)), BaseCurrencyCode = bc.CurrencyCode,
           LineCount = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines x WHERE x.DocumentId = d.Id),
           TotalQuantityBase = (SELECT SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x WHERE x.DocumentId = d.Id),
           d.Notes,
           RequestedByName = ru.FullName, RequestedAtUtc = d.ApprovalRequestedAtUtc,
           ApproverUserId = @ApproverId, ApproverName = au.FullName, LinkExpiresAtUtc = @Expires
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp   ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    OUTER APPLY (SELECT TOP (1) x.CurrencyCode FROM masterdata.Currencies x
                 WHERE x.IsBaseCurrency = 1 AND x.IsActive = 1 ORDER BY x.Id) bc
    LEFT  JOIN security.Users ru ON ru.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users au ON au.Id = @ApproverId
    WHERE d.Id = @DocId;

    SELECT l.LineNumber, i.ItemCode, i.ItemName, l.Quantity, UnitName = ut.UnitTypeName, l.QuantityBase,
           l.UnitPrice, l.DiscountPercent, l.LineTotal
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT  JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId
    LEFT  JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    WHERE l.DocumentId = @DocId
    ORDER BY l.LineNumber;
END
GO

-- The decision on the approval page (one click after opening the link). Same checks as usp_PurchaseOrder_GetByLink,
-- made again under the lock of the order. Returns usp_PurchaseOrder_DecisionResult.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DecideByLink
    @Token   NVARCHAR(200),
    @Approve BIT,
    @Reason  NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');

    IF @Approve IS NULL THROW 65000, 'Choose to approve or to reject the order.', 1;

    DECLARE @T VARCHAR(64) = CASE WHEN LEN(LTRIM(RTRIM(@Token))) = 64 THEN LOWER(LTRIM(RTRIM(@Token))) END;
    DECLARE @LinkId INT, @DocId INT, @ApproverId INT, @Problem NVARCHAR(300);

    SELECT @LinkId = l.Id, @DocId = l.PurchaseDocumentId, @ApproverId = l.UserId
    FROM purchase.PurchaseOrderApprovalLinks l
    WHERE l.TokenHash = HASHBYTES('SHA2_256', @T);

    IF @LinkId IS NULL THROW 65014, 'This approval link is not valid.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- the order is locked first: two approvers may click at the same time
        DECLARE @Locked INT;
        SELECT @Locked = d.Id FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK) WHERE d.Id = @DocId;
        IF @Locked IS NULL THROW 65014, 'This approval link is not valid.', 1;

        SET @Problem = purchase.fn_ApprovalLink_Problem(@LinkId);
        IF @Problem IS NOT NULL THROW 65014, @Problem, 1;
        EXEC purchase.usp_ApprovalLink_CheckRights @PurchaseDocumentId = @DocId, @UserId = @ApproverId;
        IF @Approve = 0 AND @Reason IS NULL THROW 65000, 'Type the reason of the rejection.', 1;

        UPDATE purchase.PurchaseOrderApprovalLinks SET UsedAtUtc = SYSUTCDATETIME() WHERE Id = @LinkId;

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @DocId, @Approve = @Approve, @Reason = @Reason,
             @UserId = @ApproverId, @Channel = 2, @Note = NULL;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @DocId;
END
GO

-- Records that the approved order was emailed to the supplier (@Sent = 1, the addresses) or could not be (@Sent = 0:
-- the supplier has no email address).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_SupplierEmailLogged
    @PurchaseDocumentId INT,
    @Sent               BIT,
    @Recipients         NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId)
        THROW 65006, 'Document not found.', 1;

    INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Recipients, Note)
    VALUES (@PurchaseDocumentId, CASE WHEN @Sent = 1 THEN 8 ELSE 9 END, @UserId, LEFT(@Recipients, 1000),
            CASE WHEN ISNULL(@Sent, 0) = 0 THEN N'The supplier has no email address.' END);

    IF @Sent = 1
        EXEC purchase.usp_PurchaseOrder_WriteAudit @PurchaseDocumentId = @PurchaseDocumentId, @Action = N'Sent to the supplier',
             @Details = @Recipients, @UserId = @UserId;
END
GO

/* ================================================================== 9. Reading the approval of an order */

-- The approval card of the order page. 2 result sets: the state for the signed-in user, the approvers of the order.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApprovalState
    @PurchaseDocumentId INT,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId)
        THROW 65006, 'Document not found.', 1;

    DECLARE @Require BIT, @Limit DECIMAL(19, 4), @AllowSelf BIT, @ReminderHours INT, @Base NVARCHAR(10);
    SELECT @Require = RequireApproval, @Limit = ApprovalLimitBase, @AllowSelf = AllowSelfApproval, @ReminderHours = ReminderHours
    FROM purchase.ApprovalSettings WHERE Id = 1;
    SELECT TOP (1) @Base = CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1 ORDER BY Id;

    DECLARE @Needs BIT = purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId);
    DECLARE @LastSent DATETIME2(0) =
        (SELECT MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
         WHERE e.PurchaseDocumentId = @PurchaseDocumentId AND e.EventType IN (1, 2, 3));
    DECLARE @IsInAppApprover BIT =
        CASE WHEN EXISTS (SELECT 1 FROM purchase.OrderApprovers a
                          INNER JOIN purchase.vw_ApprovalUsers v ON v.UserId = a.UserId AND v.IsActive = 1
                          WHERE a.UserId = @UserId AND a.CanApproveInApp = 1) THEN 1 ELSE 0 END;
    DECLARE @IsOrderApprover BIT =
        CASE WHEN EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
                          WHERE a.UserId = @UserId AND a.CanApproveInApp = 1) THEN 1 ELSE 0 END;

    SELECT PurchaseDocumentId  = d.Id, d.DocumentNumber, d.Status,
           NeedsApproval       = @Needs,
           RequireApproval     = ISNULL(@Require, CAST(1 AS BIT)),
           ApprovalLimitBase   = ISNULL(@Limit, 0),
           BaseCurrencyCode    = @Base,
           TotalBase           = ISNULL(d.TotalAmountBase, d.TotalAmount / NULLIF(d.ExchangeRate, 0)),
           AllowSelfApproval   = ISNULL(@AllowSelf, CAST(1 AS BIT)),
           UserCanApproveInApp = CAST(CASE WHEN d.Status = 5 AND @IsOrderApprover = 1 THEN 1 ELSE 0 END AS BIT),
           CanApproveDirect    = CAST(CASE WHEN d.Status = 1 AND @Needs = 1 AND ISNULL(@AllowSelf, 1) = 1
                                                AND @IsInAppApprover = 1 THEN 1 ELSE 0 END AS BIT),
           RequestedBy         = CASE WHEN d.Status = 5 THEN d.ApprovalRequestedBy END,
           RequestedByName     = CASE WHEN d.Status = 5 THEN ru.FullName END,
           RequestedAtUtc      = CASE WHEN d.Status = 5 THEN d.ApprovalRequestedAtUtc END,
           LinksValidUntilUtc  = CASE WHEN d.Status = 5 THEN lk.ValidUntil END,
           NextReminderAtUtc   = CASE WHEN d.Status = 5 AND ISNULL(@ReminderHours, 0) > 0
                                      THEN DATEADD(HOUR, @ReminderHours, COALESCE(@LastSent, d.ApprovalRequestedAtUtc)) END,
           LastRejectedByName  = CASE WHEN d.Status = 1 AND d.RejectedAtUtc IS NOT NULL THEN rju.FullName END,
           LastRejectedAtUtc   = CASE WHEN d.Status = 1 THEN d.RejectedAtUtc END,
           LastRejectReason    = CASE WHEN d.Status = 1 AND d.RejectedAtUtc IS NOT NULL THEN d.RejectReason END,
           d.ApprovedAtUtc, ApprovedByName = apu.FullName,
           SupplierEmail       = NULLIF(LTRIM(RTRIM(sp.Email)), N''),
           SentToSupplierAtUtc = s8.LastAt,
           SupplierNotEmailed  = CAST(CASE WHEN s9.LastId IS NOT NULL AND (s8.LastId IS NULL OR s8.LastId < s9.LastId)
                                           THEN 1 ELSE 0 END AS BIT),
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users ru  ON ru.Id  = d.ApprovalRequestedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    OUTER APPLY (SELECT ValidUntil = MAX(l.ExpiresAtUtc) FROM purchase.PurchaseOrderApprovalLinks l
                 WHERE l.PurchaseDocumentId = d.Id AND l.ClosedAtUtc IS NULL AND l.ExpiresAtUtc > SYSUTCDATETIME()) lk
    OUTER APPLY (SELECT LastId = MAX(e.Id), LastAt = MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 8) s8
    OUTER APPLY (SELECT LastId = MAX(e.Id) FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 9) s9
    WHERE d.Id = @PurchaseDocumentId;

    SELECT a.UserId, a.FullName, a.Email, a.CanApproveInApp, a.CanApproveByEmail,
           LinkExpiresAtUtc = (SELECT MAX(l.ExpiresAtUtc) FROM purchase.PurchaseOrderApprovalLinks l
                               WHERE l.PurchaseDocumentId = @PurchaseDocumentId AND l.UserId = a.UserId
                                 AND l.ClosedAtUtc IS NULL AND l.ExpiresAtUtc > SYSUTCDATETIME())
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
    ORDER BY a.FullName;
END
GO

-- The approval history of an order, oldest first (the "Approval" tab).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_ApprovalHistory
    @PurchaseDocumentId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.Id, e.EventType,
           EventName   = CASE e.EventType WHEN 1 THEN N'Sent for approval' WHEN 2 THEN N'Reminder sent' WHEN 3 THEN N'Sent again'
                                          WHEN 4 THEN N'Approved' WHEN 5 THEN N'Rejected' WHEN 6 THEN N'Withdrawn'
                                          WHEN 7 THEN N'Posted without approval' WHEN 8 THEN N'Sent to the supplier'
                                          WHEN 9 THEN N'Not sent to the supplier' END,
           e.Channel,
           ChannelName = CASE e.Channel WHEN 1 THEN N'In the app' WHEN 2 THEN N'By email' END,
           e.UserId, UserName = u.FullName, e.Recipients, e.Reason, e.Note, e.AtUtc
    FROM purchase.PurchaseOrderApprovalEvents e
    LEFT JOIN security.Users u ON u.Id = e.UserId
    WHERE e.PurchaseDocumentId = @PurchaseDocumentId
    ORDER BY e.Id;
END
GO

-- The orders waiting for the approval of a user in the application (Purchasing > Approvals), oldest first.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_PendingForUser
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentNumber, d.SupplierId, SupplierName = sp.PartyName, OrderDate = d.DocumentDate,
           c.CurrencyCode, Total = d.TotalAmount,
           TotalBase = ISNULL(d.TotalAmountBase, d.TotalAmount / NULLIF(d.ExchangeRate, 0)),
           LineCount = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines x WHERE x.DocumentId = d.Id),
           RequestedByName = ru.FullName, RequestedAtUtc = d.ApprovalRequestedAtUtc,
           WaitingHours = DATEDIFF(HOUR, d.ApprovalRequestedAtUtc, SYSUTCDATETIME()),
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    CROSS APPLY purchase.fn_PurchaseOrder_Approvers(d.Id) a
    LEFT  JOIN security.Users ru          ON ru.Id = d.ApprovalRequestedBy
    WHERE d.Status = 5 AND a.UserId = @UserId AND a.CanApproveInApp = 1
    ORDER BY d.ApprovalRequestedAtUtc, d.Id;
END
GO

/* ================================================================== 10. Approval settings */

-- Settings > Purchase approval. 2 result sets: the settings, every active user with his rights.
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalSettings_Get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.RequireApproval, s.ApprovalLimitBase, BaseCurrencyCode = bc.CurrencyCode, s.AllowSelfApproval,
           s.LinkValidHours, s.ReminderHours, s.NotifyAppApprovers, s.EmailSupplierOnApproval, s.CopyToOwners,
           s.CopyToEmails, s.UpdatedAtUtc, s.UpdatedBy, UpdatedByName = u.FullName, s.RowVersion
    FROM purchase.ApprovalSettings s
    LEFT JOIN security.Users u ON u.Id = s.UpdatedBy
    OUTER APPLY (SELECT TOP (1) x.CurrencyCode FROM masterdata.Currencies x
                 WHERE x.IsBaseCurrency = 1 AND x.IsActive = 1 ORDER BY x.Id) bc
    WHERE s.Id = 1;

    SELECT v.UserId, v.FullName, v.UserName, v.Email, v.Roles, v.IsAdministrator,
           CanApproveInApp   = CAST(ISNULL(a.CanApproveInApp, 0) AS BIT),
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND v.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM purchase.vw_ApprovalUsers v
    LEFT JOIN purchase.OrderApprovers a ON a.UserId = v.UserId
    WHERE v.IsActive = 1
    ORDER BY v.IsAdministrator DESC, v.FullName;
END
GO

-- Saves Settings > Purchase approval. @Approvers = every user row of the page (both rights 0 = not an approver).
-- 65024 with a message, 65004 when someone else saved in between. Returns usp_ApprovalSettings_Get.
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalSettings_Save
    @RequireApproval         BIT,
    @ApprovalLimitBase       DECIMAL(19, 4),
    @AllowSelfApproval       BIT,
    @LinkValidHours          INT,
    @ReminderHours           INT,
    @NotifyAppApprovers      BIT,
    @EmailSupplierOnApproval BIT,
    @CopyToOwners            BIT,
    @CopyToEmails            NVARCHAR(1000) = NULL,
    @Approvers               purchase.tvp_OrderApprover READONLY,
    @RowVersion              BINARY(8)      = NULL,
    @UserId                  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400);

    IF @RequireApproval IS NULL OR @AllowSelfApproval IS NULL OR @NotifyAppApprovers IS NULL
       OR @EmailSupplierOnApproval IS NULL OR @CopyToOwners IS NULL
        THROW 65024, 'Every switch of the page must be sent.', 1;
    IF @ApprovalLimitBase IS NULL OR @ApprovalLimitBase < 0 THROW 65024, 'The approval limit cannot be negative.', 1;
    IF @LinkValidHours IS NULL OR @LinkValidHours NOT BETWEEN 1 AND 720
        THROW 65024, 'Approval links must be valid between 1 and 720 hours.', 1;
    IF @ReminderHours IS NULL OR @ReminderHours NOT BETWEEN 0 AND 168
        THROW 65024, 'Reminders: between 0 (never) and 168 hours.', 1;

    SELECT TOP (1) @Msg = N'User ' + CAST(x.UserId AS NVARCHAR(10)) + N' is not an active user.'
    FROM @Approvers x
    LEFT JOIN purchase.vw_ApprovalUsers v ON v.UserId = x.UserId
    WHERE (x.CanApproveInApp = 1 OR x.CanApproveByEmail = 1) AND (v.UserId IS NULL OR v.IsActive = 0)
    ORDER BY x.UserId;
    IF @Msg IS NOT NULL THROW 65024, @Msg, 1;

    SELECT TOP (1) @Msg = ISNULL(v.FullName, N'User ' + CAST(x.UserId AS NVARCHAR(10)))
                          + N' has no email address: tick "In the app" only, or add the address to the user.'
    FROM @Approvers x
    INNER JOIN purchase.vw_ApprovalUsers v ON v.UserId = x.UserId
    WHERE x.CanApproveByEmail = 1 AND v.Email IS NULL
    ORDER BY v.FullName;
    IF @Msg IS NOT NULL THROW 65024, @Msg, 1;

    IF @RequireApproval = 1 AND NOT EXISTS (SELECT 1 FROM @Approvers WHERE CanApproveInApp = 1 OR CanApproveByEmail = 1)
        THROW 65024, 'Choose at least one approver while purchase orders need approval.', 1;

    SET @CopyToEmails = NULLIF(LTRIM(RTRIM(@CopyToEmails)), N'');

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM purchase.ApprovalSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO purchase.ApprovalSettings (Id) VALUES (1);
        ELSE IF @RowVersion IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM purchase.ApprovalSettings WHERE Id = 1 AND RowVersion = @RowVersion)
            THROW 65004, 'These settings were changed by another user. Reload the page and try again.', 1;

        UPDATE purchase.ApprovalSettings
        SET RequireApproval = @RequireApproval, ApprovalLimitBase = @ApprovalLimitBase, AllowSelfApproval = @AllowSelfApproval,
            LinkValidHours = @LinkValidHours, ReminderHours = @ReminderHours, NotifyAppApprovers = @NotifyAppApprovers,
            EmailSupplierOnApproval = @EmailSupplierOnApproval, CopyToOwners = @CopyToOwners, CopyToEmails = @CopyToEmails,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = 1;

        DELETE a
        FROM purchase.OrderApprovers a
        WHERE NOT EXISTS (SELECT 1 FROM @Approvers x
                          WHERE x.UserId = a.UserId AND (x.CanApproveInApp = 1 OR x.CanApproveByEmail = 1));

        UPDATE a
        SET CanApproveInApp = x.CanApproveInApp, CanApproveByEmail = x.CanApproveByEmail,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.OrderApprovers a
        INNER JOIN @Approvers x ON x.UserId = a.UserId
        WHERE a.CanApproveInApp <> x.CanApproveInApp OR a.CanApproveByEmail <> x.CanApproveByEmail;

        INSERT INTO purchase.OrderApprovers (UserId, CanApproveInApp, CanApproveByEmail, UpdatedBy)
        SELECT x.UserId, x.CanApproveInApp, x.CanApproveByEmail, @UserId
        FROM @Approvers x
        WHERE (x.CanApproveInApp = 1 OR x.CanApproveByEmail = 1)
          AND NOT EXISTS (SELECT 1 FROM purchase.OrderApprovers a WHERE a.UserId = x.UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_ApprovalSettings_Get;
END
GO

-- What the signed-in user may do (buttons of the order page, the Approvals menu and its count).
CREATE OR ALTER PROCEDURE purchase.usp_ApprovalSettings_ForUser
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT RequireApproval   = ISNULL(s.RequireApproval, CAST(1 AS BIT)),
           AllowSelfApproval = ISNULL(s.AllowSelfApproval, CAST(1 AS BIT)),
           ApprovalLimitBase = ISNULL(s.ApprovalLimitBase, 0),
           BaseCurrencyCode  = bc.CurrencyCode,
           CanApproveInApp   = CAST(CASE WHEN a.CanApproveInApp = 1 AND v.IsActive = 1 THEN 1 ELSE 0 END AS BIT),
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND v.IsActive = 1 AND v.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           PendingCount      = (SELECT COUNT(*)
                                FROM purchase.PurchaseDocuments d
                                INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
                                CROSS APPLY purchase.fn_PurchaseOrder_Approvers(d.Id) ap
                                WHERE d.Status = 5 AND ap.UserId = @UserId AND ap.CanApproveInApp = 1)
    FROM (SELECT One = 1) one
    LEFT JOIN purchase.ApprovalSettings s  ON s.Id = 1
    LEFT JOIN purchase.OrderApprovers a    ON a.UserId = @UserId
    LEFT JOIN purchase.vw_ApprovalUsers v  ON v.UserId = @UserId
    OUTER APPLY (SELECT TOP (1) x.CurrencyCode FROM masterdata.Currencies x
                 WHERE x.IsBaseCurrency = 1 AND x.IsActive = 1 ORDER BY x.Id) bc;
END
GO

/* ================================================================== 11. Email settings */

-- Settings > Email, without the password (HasPassword says whether one is saved).
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_Get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.SendingEnabled, s.SmtpHost, s.SmtpPort, s.SmtpSecurity, s.SmtpUserName,
           HasPassword = CAST(CASE WHEN s.SmtpPasswordProtected IS NULL THEN 0 ELSE 1 END AS BIT),
           s.FromAddress, s.FromName, s.ReplyToAddress, s.PublicBaseUrl,
           s.LastTestAtUtc, s.LastTestOk, s.LastTestError,
           IsSaved = CAST(CASE WHEN s.UpdatedAtUtc IS NULL THEN 0 ELSE 1 END AS BIT),
           s.UpdatedAtUtc, s.UpdatedBy, UpdatedByName = u.FullName, s.RowVersion
    FROM messaging.EmailSettings s
    LEFT JOIN security.Users u ON u.Id = s.UpdatedBy
    WHERE s.Id = 1;
END
GO

-- For the API only (sending): the same row with the encrypted password.
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_GetForSending
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.SendingEnabled, s.SmtpHost, s.SmtpPort, s.SmtpSecurity, s.SmtpUserName, s.SmtpPasswordProtected,
           s.FromAddress, s.FromName, s.ReplyToAddress, s.PublicBaseUrl,
           IsSaved = CAST(CASE WHEN s.UpdatedAtUtc IS NULL THEN 0 ELSE 1 END AS BIT),
           s.RowVersion
    FROM messaging.EmailSettings s
    WHERE s.Id = 1;
END
GO

-- Saves Settings > Email. @PasswordAction: 0 keep the saved password, 1 replace it with @SmtpPasswordProtected
-- (encrypted by the API), 2 remove it. 65025 with a message, 65004 when someone else saved in between.
-- Returns usp_EmailSettings_Get.
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_Save
    @SendingEnabled        BIT,
    @SmtpHost              NVARCHAR(200) = NULL,
    @SmtpPort              INT           = 587,
    @SmtpSecurity          TINYINT       = 1,
    @SmtpUserName          NVARCHAR(256) = NULL,
    @PasswordAction        TINYINT       = 0,
    @SmtpPasswordProtected NVARCHAR(MAX) = NULL,
    @FromAddress           NVARCHAR(256) = NULL,
    @FromName              NVARCHAR(200) = NULL,
    @ReplyToAddress        NVARCHAR(256) = NULL,
    @PublicBaseUrl         NVARCHAR(300) = NULL,
    @RowVersion            BINARY(8)     = NULL,
    @UserId                INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @SmtpHost       = NULLIF(LTRIM(RTRIM(@SmtpHost)), N''),
           @SmtpUserName   = NULLIF(LTRIM(RTRIM(@SmtpUserName)), N''),
           @FromAddress    = NULLIF(LTRIM(RTRIM(@FromAddress)), N''),
           @FromName       = NULLIF(LTRIM(RTRIM(@FromName)), N''),
           @ReplyToAddress = NULLIF(LTRIM(RTRIM(@ReplyToAddress)), N''),
           @PublicBaseUrl  = NULLIF(LTRIM(RTRIM(@PublicBaseUrl)), N'');
    WHILE RIGHT(@PublicBaseUrl, 1) = N'/' SET @PublicBaseUrl = LEFT(@PublicBaseUrl, LEN(@PublicBaseUrl) - 1);
    SET @PublicBaseUrl = NULLIF(@PublicBaseUrl, N'');

    IF @SendingEnabled IS NULL THROW 65025, 'Say whether emails are sent.', 1;
    IF @SmtpPort IS NULL OR @SmtpPort NOT BETWEEN 1 AND 65535 THROW 65025, 'The port must be between 1 and 65535.', 1;
    IF @SmtpSecurity IS NULL OR @SmtpSecurity NOT IN (0, 1, 2) THROW 65025, 'Unknown security option.', 1;
    IF @PasswordAction IS NULL OR @PasswordAction NOT IN (0, 1, 2) THROW 65025, 'Unknown password action.', 1;
    IF @PasswordAction = 1 AND @SmtpPasswordProtected IS NULL THROW 65025, 'The new password is missing.', 1;
    IF @FromAddress IS NOT NULL AND (@FromAddress NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @FromAddress) > 0)
        THROW 65025, 'The sender address is not a valid email address.', 1;
    IF @ReplyToAddress IS NOT NULL AND (@ReplyToAddress NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @ReplyToAddress) > 0)
        THROW 65025, 'The reply-to address is not a valid email address.', 1;
    IF @PublicBaseUrl IS NOT NULL AND @PublicBaseUrl NOT LIKE N'http://_%' AND @PublicBaseUrl NOT LIKE N'https://_%'
        THROW 65025, 'The address of the application must start with http:// or https://.', 1;
    IF @SendingEnabled = 1 AND (@SmtpHost IS NULL OR @FromAddress IS NULL)
        THROW 65025, 'Enter the mail server and the sender address before switching sending on.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO messaging.EmailSettings (Id) VALUES (1);
        ELSE IF @RowVersion IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WHERE Id = 1 AND RowVersion = @RowVersion)
            THROW 65004, 'These settings were changed by another user. Reload the page and try again.', 1;

        UPDATE messaging.EmailSettings
        SET SendingEnabled = @SendingEnabled, SmtpHost = @SmtpHost, SmtpPort = @SmtpPort, SmtpSecurity = @SmtpSecurity,
            SmtpUserName = @SmtpUserName,
            SmtpPasswordProtected = CASE @PasswordAction WHEN 1 THEN @SmtpPasswordProtected
                                                         WHEN 2 THEN NULL
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

-- The result of "Send test email". Returns the new RowVersion (the page keeps it for its next Save).
CREATE OR ALTER PROCEDURE messaging.usp_EmailSettings_SetTestResult
    @Ok    BIT,
    @Error NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WHERE Id = 1)
        INSERT INTO messaging.EmailSettings (Id) VALUES (1);

    UPDATE messaging.EmailSettings
    SET LastTestAtUtc = SYSUTCDATETIME(), LastTestOk = @Ok,
        LastTestError = CASE WHEN @Ok = 1 THEN NULL ELSE LEFT(@Error, 1000) END
    WHERE Id = 1;

    SELECT s.RowVersion FROM messaging.EmailSettings s WHERE s.Id = 1;
END
GO

/* ================================================================== 12. Check */

SELECT s.RequireApproval, s.ApprovalLimitBase, s.AllowSelfApproval, s.LinkValidHours, s.ReminderHours,
       s.NotifyAppApprovers, s.EmailSupplierOnApproval, s.CopyToOwners
FROM purchase.ApprovalSettings s;

SELECT Approver = v.FullName, a.CanApproveInApp, a.CanApproveByEmail,
       HasEmail = CASE WHEN v.Email IS NULL THEN N'no' ELSE N'yes' END, v.IsAdministrator, v.IsActive
FROM purchase.OrderApprovers a
INNER JOIN purchase.vw_ApprovalUsers v ON v.UserId = a.UserId
ORDER BY v.FullName;                                                  -- after the first run: the administrators

SELECT Users          = COUNT(*),
       Active         = SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END),
       Administrators = SUM(CASE WHEN IsAdministrator = 1 THEN 1 ELSE 0 END),
       WithRoles      = SUM(CASE WHEN Roles IS NOT NULL THEN 1 ELSE 0 END),
       WithEmail      = SUM(CASE WHEN Email IS NOT NULL THEN 1 ELSE 0 END)
FROM purchase.vw_ApprovalUsers;                                       -- Administrators above 0

SELECT ObjectName = SCHEMA_NAME(o.schema_id) + N'.' + o.name, o.type_desc
FROM sys.objects o
WHERE (SCHEMA_NAME(o.schema_id) = N'purchase'
       AND o.name IN (N'ApprovalSettings', N'OrderApprovers', N'PurchaseOrderApprovalEvents', N'PurchaseOrderApprovalLinks',
                      N'vw_ApprovalUsers', N'fn_PurchaseOrder_NeedsApproval', N'fn_PurchaseOrder_Approvers',
                      N'fn_ApprovalLink_Problem', N'usp_PurchaseOrder_WriteAudit', N'usp_PurchaseOrder_IssueRequest',
                      N'usp_PurchaseOrder_RequestRows', N'usp_ApprovalLink_CheckRights', N'usp_PurchaseOrder_ApplyDecision',
                      N'usp_PurchaseOrder_DecisionResult', N'usp_PurchaseOrder_SendForApproval', N'usp_PurchaseOrder_Resend',
                      N'usp_PurchaseOrder_DueReminders', N'usp_PurchaseOrder_WithdrawApproval', N'usp_PurchaseOrder_DecideInApp',
                      N'usp_PurchaseOrder_ApproveDirect', N'usp_PurchaseOrder_PostWithoutApproval', N'usp_PurchaseOrder_GetByLink',
                      N'usp_PurchaseOrder_DecideByLink', N'usp_PurchaseOrder_SupplierEmailLogged', N'usp_PurchaseOrder_ApprovalState',
                      N'usp_PurchaseOrder_ApprovalHistory', N'usp_PurchaseOrder_PendingForUser', N'usp_ApprovalSettings_Get',
                      N'usp_ApprovalSettings_Save', N'usp_ApprovalSettings_ForUser'))
   OR (SCHEMA_NAME(o.schema_id) = N'messaging'
       AND o.name IN (N'EmailSettings', N'usp_EmailSettings_Get', N'usp_EmailSettings_GetForSending', N'usp_EmailSettings_Save',
                      N'usp_EmailSettings_SetTestResult'))
ORDER BY ObjectName;                                                  -- expected 35 rows

SELECT p.Code, p.Name, p.Module, p.SortOrder,
       Roles = (SELECT STRING_AGG(r.Name, N', ') FROM security.RolePermissions rp
                INNER JOIN security.Roles r ON r.Id = rp.RoleId WHERE rp.PermissionId = p.Id)
FROM security.Permissions p
WHERE p.Code IN (N'settings.email.manage', N'purchase.approval.manage', N'purchase.orders.approve')
ORDER BY p.Code;

-- The new error numbers of this script must not be used by another object: expected no row.
SELECT UsedBy = OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id)
FROM sys.sql_modules m
WHERE m.[definition] LIKE N'%THROW 6502[2-5]%'
  AND OBJECT_NAME(m.object_id) NOT IN (N'usp_PurchaseOrder_SendForApproval', N'usp_PurchaseOrder_ApproveDirect',
                                       N'usp_PurchaseOrder_DecideInApp', N'usp_ApprovalLink_CheckRights',
                                       N'usp_ApprovalSettings_Save', N'usp_EmailSettings_Save');

PRINT 'Script 29 applied: purchase order approvers in the app / by email, the approval cycle, the email settings.';
GO

SET NOEXEC OFF;
GO
