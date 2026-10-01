CREATE   PROCEDURE sales.usp_ReceiptFile_Get
    @ReceiptId INT, @FileId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ReceiptId, FileName, ContentType, SizeBytes, Content
    FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
END

GO

