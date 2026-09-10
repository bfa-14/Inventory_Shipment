CREATE   PROCEDURE inventory.usp_StockDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM inventory.StockDocumentFiles WHERE Id = @Id;
END