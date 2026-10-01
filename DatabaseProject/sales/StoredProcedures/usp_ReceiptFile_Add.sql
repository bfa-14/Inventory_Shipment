/* ================================================================== 13. Files */

CREATE   PROCEDURE sales.usp_ReceiptFile_Add
    @ReceiptId        INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(300)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
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
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId AND AppliesTo = N'Receipt' AND IsActive = 1)
        THROW 71000, 'Attachment type not found, inactive, or not one for receipts.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 71000, 'The file is empty.', 1;

    INSERT INTO sales.ReceiptFiles (ReceiptId, AttachmentTypeId, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@ReceiptId, @AttachmentTypeId, @Note, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileAdded', @FileName, @UserId);
END

GO

