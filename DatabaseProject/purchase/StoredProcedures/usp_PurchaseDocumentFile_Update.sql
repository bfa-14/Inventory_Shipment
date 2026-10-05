CREATE   PROCEDURE purchase.usp_PurchaseDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255), @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Name = f.FileName, @Kind = dt.Code
    FROM purchase.PurchaseDocumentFiles f
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 65032;

    UPDATE purchase.PurchaseDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileUpdated', @Name, @UserId);
    EXEC purchase.usp_PurchaseDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END

GO

