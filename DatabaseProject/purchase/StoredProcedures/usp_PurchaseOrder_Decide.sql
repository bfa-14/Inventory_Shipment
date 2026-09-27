-- Approve posts the order (number assigned). Returns the data the API needs for the follow-up emails.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_Decide
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
    IF ISNULL(@Approve, 0) = 0 AND @Note IS NULL THROW 65000, 'A reason is required to reject a purchase order.', 1;

    DECLARE @ApprovalId INT = NULL, @DocumentId INT = NULL, @DeciderId INT = NULL, @Channel NVARCHAR(10);

    IF @Token IS NOT NULL
    BEGIN
        DECLARE @Raw VARBINARY(32) = CASE WHEN LEN(@Token) = 64 THEN TRY_CONVERT(VARBINARY(32), @Token, 2) END;
        IF @Raw IS NULL THROW 65014, 'This approval link is not valid.', 1;
        DECLARE @AStatus TINYINT, @Expires DATETIME2(3);
        SELECT @ApprovalId = Id, @DocumentId = DocumentId, @DeciderId = ApproverUserId, @AStatus = Status, @Expires = ExpiresAtUtc
        FROM purchase.PurchaseOrderApprovals WHERE TokenHash = HASHBYTES('SHA2_256', @Raw);
        IF @ApprovalId IS NULL THROW 65014, 'This approval link is not valid.', 1;
        IF @AStatus <> 1 THROW 65014, 'This approval link was already used, or the order was decided by another approver.', 1;
        IF @Expires < SYSUTCDATETIME() THROW 65014, 'This approval link has expired. Ask for the purchase order to be sent for approval again.', 1;
        SET @Channel = N'Email';
    END
    ELSE
    BEGIN
        IF @Id IS NULL OR @UserId IS NULL THROW 65000, 'The purchase order and the user are required.', 1;
        IF NOT EXISTS (SELECT 1 FROM security.UserRoles ur
                       INNER JOIN security.RolePermissions rp ON rp.RoleId = ur.RoleId
                       INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                       WHERE ur.UserId = @UserId AND p.Code = N'purchase.orders.approve')
           AND NOT EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                           WHERE ur.UserId = @UserId AND r.IsSystem = 1)
            THROW 65017, 'You are not allowed to approve purchase orders.', 1;
        SELECT @DocumentId = @Id, @DeciderId = @UserId, @Channel = N'App';
        SELECT TOP (1) @ApprovalId = Id FROM purchase.PurchaseOrderApprovals
        WHERE DocumentId = @Id AND Status = 1 AND ApproverUserId = @UserId ORDER BY RequestNo DESC;
    END

    DECLARE @DocStatus TINYINT, @TypeCode NVARCHAR(20);
    SELECT @DocStatus = d.Status, @TypeCode = dt.Code
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId;
    IF @DocStatus IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' OR @DocStatus <> 5 THROW 65014, 'This purchase order is no longer waiting for approval.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Approve = 1
        BEGIN
            EXEC purchase.usp_PurchaseDocument_Post @Id = @DocumentId, @RowVersion = NULL, @UserId = @DeciderId, @FromApproval = 1;

            UPDATE purchase.PurchaseDocuments
            SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @DeciderId, ApprovalChannel = @Channel
            WHERE Id = @DocumentId;
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET Status = 1, RejectedAtUtc = SYSUTCDATETIME(), RejectedBy = @DeciderId, RejectReason = @Note,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @DeciderId
            WHERE Id = @DocumentId;
        END

        -- the decision closes every other open link of the order
        UPDATE purchase.PurchaseOrderApprovals
        SET Status = CASE WHEN Id = @ApprovalId THEN CASE WHEN @Approve = 1 THEN 2 ELSE 3 END ELSE 4 END,
            DecidedAtUtc = SYSUTCDATETIME(),
            DecisionNote = CASE WHEN Id = @ApprovalId THEN @Note ELSE DecisionNote END,
            Channel = CASE WHEN Id = @ApprovalId THEN @Channel ELSE Channel END
        WHERE DocumentId = @DocumentId AND Status = 1;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@DocumentId, CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
                CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END + N' by '
                + ISNULL((SELECT FullName FROM security.Users WHERE Id = @DeciderId), N'?')
                + CASE WHEN @Channel = N'Email' THEN N' from the email link' ELSE N' in the application' END
                + ISNULL(N': ' + @Note, N''), @DeciderId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- For the follow-up emails.
    SELECT d.Id AS DocumentId, d.DocumentNumber,
           Decision = CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
           DecidedByName = (SELECT FullName FROM security.Users WHERE Id = @DeciderId), DecisionNote = @Note, Channel = @Channel,
           sp.PartyName AS SupplierName, sp.Email AS SupplierEmail,
           cu.FullName AS CreatorName, cu.Email AS CreatorEmail,
           rq.FullName AS RequestedByName, rq.Email AS RequestedByEmail,
           OwnerEmails = STUFF((SELECT N';' + u.Email
                                FROM security.Users u
                                INNER JOIN security.UserRoles ur ON ur.UserId = u.Id
                                INNER JOIN security.Roles r ON r.Id = ur.RoleId AND r.Name = N'Owner'
                                WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
                                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'')
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users rq ON rq.Id = d.ApprovalRequestedBy
    WHERE d.Id = @DocumentId;
END

GO

