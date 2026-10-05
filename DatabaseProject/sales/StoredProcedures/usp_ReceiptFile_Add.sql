/* ================================================================== 8. Customer receipts (RCPT) */

-- Re-created (48) from the body of script 36: the type required and used for receipts (it was optional and checked
-- on AppliesTo), + @DocumentDate; the note takes 500 characters.
CREATE   PROCEDURE sales.usp_ReceiptFile_Add
    @ReceiptId        INT,
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

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- Evidence keeps arriving after a receipt is posted (a bank statement, a payment advice), so a
    -- posted receipt takes files. A reversed one is closed.
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; files can no longer be added.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'RCPT', 71016;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 71000, 'The file is empty.', 1;

    INSERT INTO sales.ReceiptFiles (ReceiptId, AttachmentTypeId, Note, DocumentDate, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@ReceiptId, @AttachmentTypeId, @Note, @DocumentDate, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileAdded', @FileName, @UserId);
END

GO

