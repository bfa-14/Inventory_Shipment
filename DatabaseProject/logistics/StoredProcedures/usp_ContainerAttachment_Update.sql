/* ================================================================== 6. Container documents: re-link to a movement */

/* Re-created (67) from the body of script 55: + @MovementId / @SetMovement. One upload may be shared by several
   containers (attached to them together). @AllShared = 1 edits the upload and the type / date / note of every one of
   them, like deleting it everywhere; 0 edits this container's record only - and a new name or file then becomes this
   container's own copy, leaving the others on the upload as it was. (67) @SetMovement = 1 files the records edited
   (this one, or every one of the upload with @AllShared = 1) under @MovementId - NULL = General, not tied to a
   movement -, with the upload's check: every container of those records must be on that movement (70000). 0 (the
   default) leaves the link as it is. The charge link never changes here. Answers the record. */
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
    @UserId           INT            = NULL,
    @MovementId       INT            = NULL,   -- (67) with @SetMovement = 1: the movement, NULL = General
    @SetMovement      BIT            = 0       -- (67) 1 = change the movement link
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @AllShared = ISNULL(@AllShared, 0);
    SET @SetMovement = ISNULL(@SetMovement, 0);

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

    -- (67) the movement link: the upload's checks and message (usp_ContainerAttachment_Add)
    DECLARE @Msg NVARCHAR(400), @Moved BIT = 0, @MovementText NVARCHAR(60) = NULL;
    IF @SetMovement = 1
    BEGIN
        IF @MovementId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId) THROW 70006, 'Movement not found.', 1;
            SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not part of this movement.'
            FROM @Rows r INNER JOIN logistics.Containers c ON c.Id = r.ContainerId
            WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = r.ContainerId)
            ORDER BY c.ContainerRef;
            IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
        END
        IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments a INNER JOIN @Rows r ON r.Id = a.Id
                   WHERE ISNULL(a.MovementId, -1) <> ISNULL(@MovementId, -1))
        BEGIN
            SET @Moved = 1;
            SET @MovementText = ISNULL(N' (movement ' + (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId) + N')', N' (General)');
        END
    END

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

        UPDATE a SET AttachmentTypeId = @AttachmentTypeId, Note = @Note, DocumentDate = @DocumentDate,
                     MovementId = CASE WHEN @SetMovement = 1 THEN @MovementId ELSE a.MovementId END   -- (67)
        FROM logistics.ContainerAttachments a INNER JOIN @Rows r ON r.Id = a.Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT DISTINCT r.ContainerId, N'Updated',
               LEFT(N'Attachment edited: ' + CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                    + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END
                    + CASE WHEN @Moved = 1 THEN @MovementText ELSE N'' END, 500), @UserId   -- (67)
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

