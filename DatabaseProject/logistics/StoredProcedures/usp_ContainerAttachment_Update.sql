/* ================================================================== 6. Container documents (CONTAINER) */

/* One upload may be shared by several containers (attached to them together). @AllShared = 1 edits the
   upload and the type / date / note of every one of them, like deleting it everywhere; 0 edits this
   container's record only - and a new name or file then becomes this container's own copy, leaving the
   others on the upload as it was. Answers the record. */
CREATE   PROCEDURE logistics.usp_ContainerAttachment_Update
    @Id               INT,
    @AllShared        BIT            = 0,
    @AttachmentTypeId INT            = NULL,
    @DocumentDate     DATE           = NULL,
    @Note             NVARCHAR(500)  = NULL,
    @FileName         NVARCHAR(255)  = NULL,
    @ContentType      NVARCHAR(100)  = NULL,
    @SizeBytes        INT            = NULL,
    @Content          VARBINARY(MAX) = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @AllShared = ISNULL(@AllShared, 0);

    DECLARE @FileId INT, @Old NVARCHAR(255), @OldType INT;
    SELECT @FileId = a.FileId, @Old = f.FileName, @OldType = a.AttachmentTypeId
    FROM logistics.ContainerAttachments a INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
    IF @FileId IS NULL THROW 70006, 'Attachment not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'CONTAINER', 70017;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 70000, 'The file is empty.', 1;

    DECLARE @Shared BIT = CASE WHEN EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE FileId = @FileId AND Id <> @Id) THEN 1 ELSE 0 END;
    DECLARE @Rows TABLE (Id INT PRIMARY KEY, ContainerId INT NOT NULL);
    INSERT INTO @Rows (Id, ContainerId)
    SELECT Id, ContainerId FROM logistics.ContainerAttachments WHERE Id = @Id OR (@AllShared = 1 AND FileId = @FileId);

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Shared = 1 AND @AllShared = 0 AND (@Content IS NOT NULL OR @FileName <> @Old)
        BEGIN
            -- this container's own copy: the others keep the upload as it was
            INSERT INTO logistics.Files (FileName, ContentType, SizeBytes, Content, CreatedBy)
            SELECT @FileName,
                   CASE WHEN @Content IS NULL THEN f.ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
                   CASE WHEN @Content IS NULL THEN f.SizeBytes ELSE @SizeBytes END,
                   ISNULL(@Content, f.Content), @UserId
            FROM logistics.Files f WHERE f.Id = @FileId;
            UPDATE logistics.ContainerAttachments SET FileId = SCOPE_IDENTITY(), GroupId = NULL WHERE Id = @Id;
        END
        ELSE
            UPDATE logistics.Files
            SET FileName    = @FileName,
                ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
                SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
                Content     = ISNULL(@Content, Content)
            WHERE Id = @FileId;

        UPDATE a SET AttachmentTypeId = @AttachmentTypeId, Note = @Note, DocumentDate = @DocumentDate
        FROM logistics.ContainerAttachments a INNER JOIN @Rows r ON r.Id = a.Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT DISTINCT r.ContainerId, N'Updated',
               LEFT(N'Attachment edited: ' + CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                    + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId
        FROM @Rows r;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC logistics.usp_ContainerAttachment_List @Id = @Id;
END

GO

