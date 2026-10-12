CREATE   PROCEDURE purchase.usp_PaymentFile_Update
    @PaymentId INT, @FileId INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; its files can no longer be changed.', 1;
    DECLARE @Old NVARCHAR(255), @OldType INT;
    SELECT @Old = FileName, @OldType = AttachmentTypeId FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
    IF @Old IS NULL THROW 73006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'PAY', 73013;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 73000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE purchase.PaymentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @FileId AND PaymentId = @PaymentId;
    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
    VALUES (@PaymentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                             + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC purchase.usp_PaymentFile_List @PaymentId = @PaymentId, @FileId = @FileId;
END

GO

