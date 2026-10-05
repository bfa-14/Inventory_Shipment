CREATE   PROCEDURE sales.usp_ReceiptFile_Update
    @ReceiptId INT, @FileId INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(255), @Status TINYINT;
    SELECT @Name = f.FileName, @Status = r.Status
    FROM sales.ReceiptFiles f INNER JOIN sales.Receipts r ON r.Id = f.ReceiptId
    WHERE f.Id = @FileId AND f.ReceiptId = @ReceiptId;
    IF @Name IS NULL THROW 71006, 'File not found.', 1;
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be changed.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'RCPT', 71016;

    UPDATE sales.ReceiptFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @FileId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileUpdated', @Name, @UserId);
    EXEC sales.usp_ReceiptFile_List @ReceiptId = @ReceiptId, @FileId = @FileId;
END

GO

