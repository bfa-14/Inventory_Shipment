/* ================================================================== 2. Withdraw, with its reason */

-- 6.5 Pending approval -> Draft again (the requester changed their mind); the emailed links stop working. The reason
-- (optional) is kept on the "Withdrawn" event and in the audit line.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_Withdraw
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

