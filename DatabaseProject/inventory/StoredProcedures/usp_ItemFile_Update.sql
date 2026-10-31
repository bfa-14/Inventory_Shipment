-- note (a type is required, active and used for items, except that a file may keep the type it has though it was
-- deactivated since), @FileName (NULL or blank keeps it) and optionally a new version of the file (NULL keeps the
-- stored one). Answers the file's row (usp_ItemFile_List's). The picture: its name and file only, as before (no row
-- answered: the list never shows it). @UserId is taken for the callers' shape; an item keeps no audit of its files.
CREATE   PROCEDURE inventory.usp_ItemFile_Update
    @Id          INT,
    @FileName    NVARCHAR(255)  = NULL,   -- (67) NULL / blank keeps the name
    @ContentType NVARCHAR(100)  = NULL,   -- with @Content: a new version of the file
    @SizeBytes   INT            = NULL,
    @Content     VARBINARY(MAX) = NULL,
    @AttachmentTypeId INT           = NULL,   -- (67)
    @DocumentDate     DATE          = NULL,   -- (67)
    @Note             NVARCHAR(500) = NULL,   -- (67)
    @UserId           INT           = NULL    -- (67)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ItemId INT, @Old NVARCHAR(255), @OldType INT, @IsImage BIT;
    SELECT @ItemId = ItemId, @Old = FileName, @OldType = AttachmentTypeId, @IsImage = IsItemImage
    FROM inventory.ItemFiles WHERE Id = @Id;
    IF @ItemId IS NULL THROW 56006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    -- the type the file has may stay though deactivated since; a new choice is checked as the upload's
    IF @IsImage = 0 AND (@AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1))
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'ITEM', 56009;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 56000, 'The file is empty.', 1;

    UPDATE inventory.ItemFiles
    SET FileName         = @FileName,
        ContentType      = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes        = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content          = ISNULL(@Content, Content),
        AttachmentTypeId = CASE WHEN IsItemImage = 1 THEN NULL ELSE @AttachmentTypeId END,
        DocumentDate     = CASE WHEN IsItemImage = 1 THEN NULL ELSE @DocumentDate END,
        Note             = CASE WHEN IsItemImage = 1 THEN NULL ELSE NULLIF(LTRIM(RTRIM(@Note)), N'') END
    WHERE Id = @Id;

    EXEC inventory.usp_ItemFile_List @ItemId = @ItemId, @FileId = @Id;
END

GO

