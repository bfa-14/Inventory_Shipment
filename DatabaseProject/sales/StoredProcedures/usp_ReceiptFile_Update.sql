/* ================================================================== 4. Customer receipts (RCPT) */

CREATE   PROCEDURE sales.usp_ReceiptFile_Update
    @ReceiptId INT, @FileId INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be changed.', 1;
    DECLARE @Old NVARCHAR(255), @OldType INT;
    SELECT @Old = FileName, @OldType = AttachmentTypeId FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    IF @Old IS NULL THROW 71006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'RCPT', 71016;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 71000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE sales.ReceiptFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
    VALUES (@ReceiptId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                             + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC sales.usp_ReceiptFile_List @ReceiptId = @ReceiptId, @FileId = @FileId;
END

GO

