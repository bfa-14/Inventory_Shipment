-- approver). Returns what usp_ApprovalSettings_Get returns.
CREATE   PROCEDURE purchase.usp_ApprovalSettings_Save
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

