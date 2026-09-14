CREATE   PROCEDURE purchase.usp_PurchaseDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
END