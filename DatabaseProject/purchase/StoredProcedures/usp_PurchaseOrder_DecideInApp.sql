/* ================================================================== 7. New procedures */

-- 7.1 Approve or reject in the application, by an in-app approver of the order. Same result set as usp_PurchaseOrder_Decide.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_DecideInApp
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

