
-- Pending approval -> Draft again (the requester changed their mind); the emailed links stop working.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_Withdraw
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
        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = SYSUTCDATETIME() WHERE DocumentId = @Id AND Status = 1;
        UPDATE purchase.PurchaseDocuments SET Status = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
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

