CREATE   PROCEDURE inventory.usp_StockDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM inventory.StockDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 62006, 'File not found.', 1;
    DELETE FROM inventory.StockDocumentFiles WHERE Id = @Id;
    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END