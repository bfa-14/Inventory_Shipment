CREATE   PROCEDURE sales.usp_SalesDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM sales.SalesDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    DELETE FROM sales.SalesDocumentFiles WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END

GO

