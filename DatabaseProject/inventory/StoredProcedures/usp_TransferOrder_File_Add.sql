/* 13.15 Files */

-- The transfer order's files, in the shape of the goods receipts' (script 64): a type used for transfer orders (62011
-- through usp_AttachmentType_CheckForKind, kind TRO), a document date, a note. A waybill or a damage report may come
-- at any time, so every status takes files.
CREATE   PROCEDURE inventory.usp_TransferOrder_File_Add
    @TransferOrderId  INT,
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
    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @TransferOrderId) THROW 62006, 'Transfer order not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 62000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 62000, 'The file is empty.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'TRO', 62011;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO inventory.TransferOrderFiles (TransferOrderId, AttachmentTypeId, DocumentDate, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@TransferOrderId, @AttachmentTypeId, @DocumentDate, NULLIF(LTRIM(RTRIM(@Note)), N''), LTRIM(RTRIM(@FileName)),
                ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@TransferOrderId, N'FileAdded', LEFT(LTRIM(RTRIM(@FileName)), 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

