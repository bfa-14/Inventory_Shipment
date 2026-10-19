/* ================================================================== 21. Files */

-- The goods receipt's files, in the shape of the purchase documents' (scripts 52 and 55): a type used for goods
-- receipts (63012 through usp_AttachmentType_CheckForKind), a document date, a note. A delivery note or a damage
-- report may come after the posting, so every status takes files, as the purchase documents do.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_File_Add
    @GoodsReceiptId   INT,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT           = NULL,
    @NewId            INT           = NULL OUTPUT,
    @AttachmentTypeId INT           = NULL,
    @DocumentDate     DATE          = NULL,
    @Note             NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @GoodsReceiptId) THROW 63006, 'Goods receipt not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 63000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 63000, 'The file is empty.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'GRN', 63012;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO purchase.GoodsReceiptFiles (GoodsReceiptId, AttachmentTypeId, DocumentDate, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@GoodsReceiptId, @AttachmentTypeId, @DocumentDate, NULLIF(LTRIM(RTRIM(@Note)), N''), LTRIM(RTRIM(@FileName)),
                ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
        VALUES (@GoodsReceiptId, N'FileAdded', LEFT(LTRIM(RTRIM(@FileName)), 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

