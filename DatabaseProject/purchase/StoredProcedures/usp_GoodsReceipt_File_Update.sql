-- row (usp_GoodsReceipt_File_List). A type the file already has may stay though deactivated since.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_File_Update
    @Id               INT,
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
    DECLARE @ReceiptId INT, @Old NVARCHAR(255), @OldType INT;
    SELECT @ReceiptId = GoodsReceiptId, @Old = FileName, @OldType = AttachmentTypeId FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
    IF @ReceiptId IS NULL THROW 63006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'GRN', 63012;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 63000, 'The file is empty.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.GoodsReceiptFiles
        SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
            FileName    = @FileName,
            ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
            SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
            Content     = ISNULL(@Content, Content)
        WHERE Id = @Id;
        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
        VALUES (@ReceiptId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                                 + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_GoodsReceipt_File_List @GoodsReceiptId = @ReceiptId, @FileId = @Id;
END

GO

