-- Self-approval must be allowed: the user approves an order of their own here. Same result set as usp_PurchaseOrder_Decide.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_ApproveDirect
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

