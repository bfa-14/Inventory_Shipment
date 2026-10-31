/* ================================================================== 4. Item file procedures */

-- Re-created (67) from the body of script 11: a document (@IsItemImage 0) needs a type used for items, and takes a
-- document date and a note (56009 'Choose the attachment type.' / 'The attachment type {name} is not used for
-- items.'). THE PICTURE (@IsItemImage 1) IS UNCHANGED: no type check, it replaces the item's picture, and it keeps no
-- type, date or note.
CREATE   PROCEDURE inventory.usp_ItemFile_Add
    @ItemId      INT,
    @FileName    NVARCHAR(255),
    @ContentType NVARCHAR(100),
    @SizeBytes   INT,
    @IsItemImage BIT,
    @Content     VARBINARY(MAX),
    @UserId      INT = NULL,
    @NewId       INT OUTPUT,
    @AttachmentTypeId INT           = NULL,   -- (67) required for a document, ignored for the picture
    @DocumentDate     DATE          = NULL,   -- (67)
    @Note             NVARCHAR(500) = NULL    -- (67)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @IsItemImage = ISNULL(@IsItemImage, 0);

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId)
        THROW 56006, 'Item not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 56000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 56000, 'The file is empty.', 1;
    IF @IsItemImage = 0
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'ITEM', 56009;   -- (67)
    ELSE
        SELECT @AttachmentTypeId = NULL, @DocumentDate = NULL, @Note = NULL;                -- (67) the picture has none

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsItemImage = 1
            DELETE FROM inventory.ItemFiles WHERE ItemId = @ItemId AND IsItemImage = 1;  -- replace the image

        INSERT INTO inventory.ItemFiles (ItemId, FileName, ContentType, SizeBytes, IsItemImage, Content, CreatedBy,
                                         AttachmentTypeId, DocumentDate, Note)
        VALUES (@ItemId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @IsItemImage, @Content, @UserId,
                @AttachmentTypeId, @DocumentDate, NULLIF(LTRIM(RTRIM(@Note)), N''));

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

