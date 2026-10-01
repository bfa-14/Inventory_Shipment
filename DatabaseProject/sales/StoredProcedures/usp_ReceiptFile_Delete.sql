CREATE   PROCEDURE sales.usp_ReceiptFile_Delete
    @ReceiptId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- Evidence of a posted payment is not removable: that is what it is evidence of.
    IF @Status <> 1 THROW 71005, 'Files can only be removed from a draft receipt.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId);
    IF @Name IS NULL THROW 71006, 'File not found.', 1;

    DELETE FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileDeleted', @Name, @UserId);
END

GO

