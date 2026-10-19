CREATE   PROCEDURE purchase.usp_GoodsReceipt_File_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, GoodsReceiptId AS DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc
    FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
END

GO

