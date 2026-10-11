/* ================================================================== 5. Supplier payments (PAY) */

-- Re-created (55) from the body of script 47: the type required and used for payments (it was optional and checked
-- on AppliesTo), + @DocumentDate; the note takes 500 characters.
CREATE   PROCEDURE purchase.usp_PaymentFile_Add
    @PaymentId        INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(500)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT,
    @DocumentDate     DATE           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    -- Evidence keeps arriving after a payment is posted (a SWIFT copy, a bank statement), so a posted payment
    -- takes files. A reversed one is closed.
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; files can no longer be added.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'PAY', 73013;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 73000, 'The file is empty.', 1;

    INSERT INTO purchase.PaymentFiles (PaymentId, AttachmentTypeId, Note, DocumentDate, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@PaymentId, @AttachmentTypeId, @Note, @DocumentDate, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@PaymentId, N'FileAdded', @FileName, @UserId);
END

GO

