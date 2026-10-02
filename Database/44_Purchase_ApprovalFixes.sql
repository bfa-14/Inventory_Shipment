/* =====================================================================================
   Inventory_Shipment - 44: PURCHASE APPROVAL - SUPPLIER EMAIL CHECK AND WITHDRAWAL REASON (prompt 42 A1)

   Rules
     - Sending an order for approval refuses a supplier without an email address (65016) ONLY while "Email the
       approved order to the supplier" is on (purchase.ApprovalSettings.EmailSupplierOnApproval = 1): with the
       setting off nothing is emailed to the supplier, so the address is not needed. usp_PurchaseOrder_RequestApproval
       is the only procedure that throws 65016 (ApproveDirect, Resend, Decide and the create paths of the API never
       did: an approval without a supplier address is recorded as "Not sent to the supplier", event 9).
     - Withdrawing a request keeps the reason typed by the requester: usp_PurchaseOrder_Withdraw takes @Reason
       (default NULL, so the callers of script 42 are unchanged); it is stored on the "Withdrawn" event (event 6,
       shown by usp_PurchaseOrder_ApprovalHistory) and in the document's audit line.

   Objects
     purchase.usp_PurchaseOrder_RequestApproval  (re-created from its current body, script 42)
     purchase.usp_PurchaseOrder_Withdraw         (re-created from its current body, script 42, + @Reason)

   Errors: 65016 supplier without email (setting on), 65004 concurrency, 65006 not found, 65008 inactive supplier,
           65009 no lines, 65010 invalid status, 65015 no approver, 65022 approval not needed.

   Requires script 42. Idempotent, additive: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.ApprovalSettings', N'U') IS NULL
   OR COL_LENGTH(N'purchase.ApprovalSettings', N'EmailSupplierOnApproval') IS NULL
   OR COL_LENGTH(N'purchase.PurchaseOrderApprovalEvents', N'Reason') IS NULL
   OR OBJECT_ID(N'purchase.usp_PurchaseOrder_IssueLinks', N'P') IS NULL
BEGIN
    RAISERROR ('Run script 42 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Send for approval */

-- 6.2 Draft PO -> Pending approval. Returns one row per approver: a personal token (shown ONCE, only its hash is kept)
-- for the by-email approvers, none for the in-app ones; SendEmail = whether the API emails that approver.
-- 65016 only while the approved order is emailed to the supplier (ApprovalSettings.EmailSupplierOnApproval).
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

/* ================================================================== 2. Withdraw, with its reason */

-- 6.5 Pending approval -> Draft again (the requester changed their mind); the emailed links stop working. The reason
-- (optional) is kept on the "Withdrawn" event and in the audit line.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Withdraw
    @Id     INT,
    @UserId INT           = NULL,
    @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be withdrawn.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PurchaseDocuments SET Status = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id AND Status = 5;
        IF @@ROWCOUNT = 0 THROW 65010, 'Only a purchase order waiting for approval can be withdrawn.', 1;
        INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Reason)
        VALUES (@Id, 6, @UserId, @Reason);
        DECLARE @EventId BIGINT = SCOPE_IDENTITY();
        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = SYSUTCDATETIME(), ClosedByEventId = @EventId
        WHERE DocumentId = @Id AND Status = 1;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', LEFT(N'Approval request withdrawn' + ISNULL(N': ' + @Reason, N''), 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 3. Check */

SELECT p.ProcedureName,
       ObjectType = ISNULL(so.type_desc, N'MISSING'),
       HasReasonParameter = CASE WHEN p.ProcedureName LIKE N'%Withdraw'
                                 THEN CASE WHEN EXISTS (SELECT 1 FROM sys.parameters pr
                                                        WHERE pr.object_id = OBJECT_ID(p.ProcedureName) AND pr.name = N'@Reason')
                                           THEN N'yes' ELSE N'NO' END END
FROM (VALUES (N'purchase.usp_PurchaseOrder_RequestApproval'), (N'purchase.usp_PurchaseOrder_Withdraw')) p (ProcedureName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(p.ProcedureName)
ORDER BY p.ProcedureName;                                             -- expected 2 procedures, none MISSING, reason yes

-- What the setting means today: with it off, suppliers without an address can be sent for approval.
SELECT EmailSupplierOnApproval,
       SuppliersWithoutEmail = (SELECT COUNT(*) FROM masterdata.Parties
                                WHERE IsActive = 1 AND IsSupplier = 1 AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NULL)
FROM purchase.ApprovalSettings WHERE Id = 1;

PRINT 'Script 44 applied: 65016 only while the approved order is emailed to the supplier; the withdrawal keeps its reason.';
GO

SET NOEXEC OFF;
GO
