CREATE   PROCEDURE sales.usp_ReceiptFile_Delete
    @ReceiptId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- (49) a draft or a posted receipt; a reversed one is closed. Every removal is in the receipt's audit.
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be removed.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId);
    IF @Name IS NULL THROW 71006, 'File not found.', 1;

    DELETE FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileDeleted', @Name, @UserId);
END

GO

