CREATE   PROCEDURE purchase.usp_PurchaseDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    DELETE FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END