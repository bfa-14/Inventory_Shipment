/* ================================================================== 6. Sales documents (SO, SINV, SRET) */

-- Re-created (48) from the body of script 17: + the type (required, used for the document's kind), date and note.
CREATE   PROCEDURE sales.usp_SalesDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT,
    @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @DocumentId) THROW 64006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 64000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 64000, 'The file is empty.', 1;
    DECLARE @Kind NVARCHAR(20) = (SELECT dt.Code FROM sales.SalesDocuments d
                                  INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId);
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 64017;

    INSERT INTO sales.SalesDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy, AttachmentTypeId, DocumentDate, Note)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId, @AttachmentTypeId, @DocumentDate,
            NULLIF(LTRIM(RTRIM(@Note)), N''));
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END

GO

