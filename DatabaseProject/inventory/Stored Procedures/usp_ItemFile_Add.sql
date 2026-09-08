/* ------------------------------------------------------------------ Item file procedures */

CREATE   PROCEDURE inventory.usp_ItemFile_Add
    @ItemId      INT,
    @FileName    NVARCHAR(255),
    @ContentType NVARCHAR(100),
    @SizeBytes   INT,
    @IsItemImage BIT,
    @Content     VARBINARY(MAX),
    @UserId      INT = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId)
        THROW 56006, 'Item not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 56000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 56000, 'The file is empty.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsItemImage = 1
            DELETE FROM inventory.ItemFiles WHERE ItemId = @ItemId AND IsItemImage = 1;  -- replace the image

        INSERT INTO inventory.ItemFiles (ItemId, FileName, ContentType, SizeBytes, IsItemImage, Content, CreatedBy)
        VALUES (@ItemId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, ISNULL(@IsItemImage, 0), @Content, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END