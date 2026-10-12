CREATE   PROCEDURE sales.usp_SalesDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @DocumentId INT, @Old NVARCHAR(255), @OldType INT, @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Old = f.FileName, @OldType = f.AttachmentTypeId, @Kind = dt.Code
    FROM sales.SalesDocumentFiles f
    INNER JOIN sales.SalesDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 64017;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 64000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE sales.SalesDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC sales.usp_SalesDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END

GO

