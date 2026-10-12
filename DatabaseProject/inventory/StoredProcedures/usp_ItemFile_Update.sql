/* ================================================================== 1. Items */

CREATE   PROCEDURE inventory.usp_ItemFile_Update
    @Id          INT,
    @FileName    NVARCHAR(255),
    @ContentType NVARCHAR(100)  = NULL,   -- with @Content: a new version of the file
    @SizeBytes   INT            = NULL,
    @Content     VARBINARY(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    IF NOT EXISTS (SELECT 1 FROM inventory.ItemFiles WHERE Id = @Id) THROW 56006, 'File not found.', 1;
    IF @FileName IS NULL THROW 56000, 'File name is required.', 1;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 56000, 'The file is empty.', 1;

    UPDATE inventory.ItemFiles
    SET FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
END

GO

