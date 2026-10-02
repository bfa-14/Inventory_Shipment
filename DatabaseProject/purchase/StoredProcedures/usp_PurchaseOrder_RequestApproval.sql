/* ================================================================== 1. Send for approval */

-- 6.2 Draft PO -> Pending approval. Returns one row per approver: a personal token (shown ONCE, only its hash is kept)
-- for the by-email approvers, none for the in-app ones; SendEmail = whether the API emails that approver.
-- 65016 only while the approved order is emailed to the supplier (ApprovalSettings.EmailSupplierOnApproval).
CREATE   PROCEDURE purchase.usp_PurchaseOrder_RequestApproval
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
    IF ISNULL((SELECT EmailSupplierOnApproval FROM purchase.ApprovalSettings WHERE Id = 1), 0) = 1
       AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL)
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

