
-- Draft PO -> Pending approval. Returns one row per approver with the personal token (shown ONCE, only its hash is kept).
CREATE   PROCEDURE purchase.usp_PurchaseOrder_RequestApproval
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @ValidHours INT       = 72
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @ValidHours IS NULL OR @ValidHours < 1 SET @ValidHours = 72;

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

    DECLARE @Approvers TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, UserId INT, FullName NVARCHAR(100), Email NVARCHAR(256), Token VARBINARY(32) NULL);
    INSERT INTO @Approvers (UserId, FullName, Email)
    SELECT DISTINCT u.Id, u.FullName, u.Email
    FROM security.Users u
    INNER JOIN security.UserRoles ur      ON ur.UserId = u.Id
    INNER JOIN security.Roles r           ON r.Id = ur.RoleId AND r.IsSystem = 0
    INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
    INNER JOIN security.Permissions p     ON p.Id = rp.PermissionId AND p.Code = N'purchase.orders.approve'
    WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @Approvers)
        THROW 65015, 'Nobody can approve: give the permission "Approve Purchase Orders" to a role (Manager / Owner) whose users have an email.', 1;

    -- One cryptographic token per approver (generated row by row).
    DECLARE @Seq INT = 1, @Max INT = (SELECT MAX(Seq) FROM @Approvers);
    WHILE @Seq <= @Max
    BEGIN
        UPDATE @Approvers SET Token = CRYPT_GEN_RANDOM(32) WHERE Seq = @Seq;
        SET @Seq += 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RequestNo INT = ISNULL((SELECT MAX(RequestNo) FROM purchase.PurchaseOrderApprovals WHERE DocumentId = @Id), 0) + 1;
        DECLARE @Expires DATETIME2(3) = DATEADD(HOUR, @ValidHours, SYSUTCDATETIME());

        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = SYSUTCDATETIME()
        WHERE DocumentId = @Id AND Status = 1;

        INSERT INTO purchase.PurchaseOrderApprovals (DocumentId, RequestNo, ApproverUserId, TokenHash, ExpiresAtUtc, RequestedBy)
        SELECT @Id, @RequestNo, a.UserId, HASHBYTES('SHA2_256', a.Token), @Expires, @UserId FROM @Approvers a;

        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = SYSUTCDATETIME(), ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Sent for approval to ' + CAST((SELECT COUNT(*) FROM @Approvers) AS NVARCHAR(10)) + N' approver(s)', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT a.UserId, a.FullName, a.Email, Token = CONVERT(VARCHAR(64), a.Token, 2), ExpiresAtUtc = @Expires, RequestNo = @RequestNo
    FROM @Approvers a ORDER BY a.FullName;
END

GO

