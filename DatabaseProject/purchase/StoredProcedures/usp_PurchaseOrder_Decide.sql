-- approver (@Id + @UserId; the API uses usp_PurchaseOrder_DecideInApp). Approve posts the order (number assigned).
-- Returns the data the API needs for the follow-up emails.
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
    SET @Approve = ISNULL(@Approve, 0);
    IF @Approve = 0 AND @Note IS NULL THROW 65000, 'A reason is required to reject a purchase order.', 1;

    DECLARE @ApprovalId INT = NULL, @DocumentId INT = NULL, @DeciderId INT = NULL, @Channel TINYINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Token IS NOT NULL
        BEGIN
            -- 65014 (what happened to the link), 65023 (self-approval), 65017 (no longer a by-email approver)
            EXEC purchase.usp_PurchaseOrder_CheckToken @Token = @Token, @ApprovalId = @ApprovalId OUTPUT,
                 @DocumentId = @DocumentId OUTPUT, @ApproverId = @DeciderId OUTPUT;
            SET @Channel = 2;
        END
        ELSE
        BEGIN
            IF @Id IS NULL OR @UserId IS NULL THROW 65000, 'The purchase order and the user are required.', 1;
            DECLARE @DocStatus TINYINT, @TypeCode NVARCHAR(20);
            SELECT @DocStatus = d.Status, @TypeCode = dt.Code
            FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
            WHERE d.Id = @Id;
            IF @DocStatus IS NULL THROW 65006, 'Document not found.', 1;
            IF @TypeCode <> N'PO' OR @DocStatus <> 5 THROW 65014, 'This purchase order is no longer waiting for approval.', 1;
            EXEC purchase.usp_PurchaseOrder_CheckApprover @PurchaseDocumentId = @Id, @UserId = @UserId, @Channel = 1;
            SELECT @DocumentId = @Id, @DeciderId = @UserId, @Channel = 1;
        END

        EXEC purchase.usp_PurchaseOrder_ApplyDecision @PurchaseDocumentId = @DocumentId, @Approve = @Approve, @Reason = @Note,
             @UserId = @DeciderId, @Channel = @Channel, @ApprovalId = @ApprovalId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseOrder_DecisionResult @PurchaseDocumentId = @DocumentId, @Approve = @Approve, @UserId = @DeciderId,
         @Note = @Note, @Channel = @Channel;
END

GO

