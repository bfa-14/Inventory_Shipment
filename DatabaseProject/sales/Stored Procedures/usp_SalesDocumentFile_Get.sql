CREATE   PROCEDURE sales.usp_SalesDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM sales.SalesDocumentFiles WHERE Id = @Id;
END