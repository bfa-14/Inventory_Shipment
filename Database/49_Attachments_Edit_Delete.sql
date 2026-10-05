SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   49: Attachments - edit and delete everywhere
   --------------------------------------------------------------------------------------------------
   Every attachment can now be EDITED as well as deleted: its details and, optionally, the file itself
   (a new version replaces the old one in the same place in the list).

     inventory.usp_ItemFile_Update            file name; optionally a new file
     inventory.usp_StockDocumentFile_Update   file name; optionally a new file           (audited)
     sales.usp_SalesDocumentFile_Update       file name; optionally a new file           (audited)
     purchase.usp_PurchaseDocumentFile_Update file name; optionally a new file           (audited)
     sales.usp_ReceiptFile_Update             type, note, file name; optionally a new file (audited)
     purchase.usp_PaymentFile_Update          type, note, file name; optionally a new file (audited)
     logistics.usp_ContainerAttachment_Update type, note, document date, file name; optionally a new
                                              file - for this container only or for every container
                                              sharing the upload                          (audited)

   WHEN: at any status of the document. The one exception is a REVERSED receipt or payment, which is
   closed: its files can be neither edited nor deleted (as they could not be added). So
   usp_ReceiptFile_Delete and usp_PaymentFile_Delete now also work on a POSTED receipt / payment.

   A NEW FILE keeps the rules of an added one (not empty; the API checks the type and the size).
   Leaving it out keeps the stored file and only changes the details.
   ================================================================================================== */

IF OBJECT_ID(N'purchase.usp_PaymentFile_Delete', N'P') IS NULL OR OBJECT_ID(N'logistics.usp_ContainerAttachment_Delete', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts up to 47 before script 49.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Items */

CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_Update
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

/* ================================================================== 2. Inventory In / Out, sales and purchase documents */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Update
    @Id INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    DECLARE @DocumentId INT, @Old NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Old = FileName FROM inventory.StockDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 62006, 'File not found.', 1;
    IF @FileName IS NULL THROW 62000, 'File name is required.', 1;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 62000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE inventory.StockDocumentFiles
    SET FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Update
    @Id INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    DECLARE @DocumentId INT, @Old NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Old = FileName FROM sales.SalesDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    IF @FileName IS NULL THROW 64000, 'File name is required.', 1;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 64000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE sales.SalesDocumentFiles
    SET FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Update
    @Id INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    DECLARE @DocumentId INT, @Old NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Old = FileName FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    IF @FileName IS NULL THROW 65000, 'File name is required.', 1;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 65000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE purchase.PurchaseDocumentFiles
    SET FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;
END
GO

/* ================================================================== 3. Customer receipts */

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Update
    @ReceiptId        INT,
    @FileId           INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(300)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100)  = NULL,
    @SizeBytes        INT            = NULL,
    @Content          VARBINARY(MAX) = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be changed.', 1;
    DECLARE @Old NVARCHAR(255), @OldType INT;
    SELECT @Old = FileName, @OldType = AttachmentTypeId FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    IF @Old IS NULL THROW 71006, 'File not found.', 1;
    IF @FileName IS NULL THROW 71000, 'File name is required.', 1;
    -- a type kept as it was may since have been deactivated; a NEW choice must be an active receipt type
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId AND AppliesTo = N'Receipt'
                                                     AND (IsActive = 1 OR @AttachmentTypeId = @OldType))
        THROW 71000, 'Attachment type not found, inactive, or not one for receipts.', 1;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 71000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE sales.ReceiptFiles
    SET AttachmentTypeId = @AttachmentTypeId, Note = @Note, FileName = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
    VALUES (@ReceiptId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                             + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Delete
    @ReceiptId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- (49) a draft or a posted receipt; a reversed one is closed. Every removal is in the receipt's audit.
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be removed.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId);
    IF @Name IS NULL THROW 71006, 'File not found.', 1;

    DELETE FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 4. Supplier payments */

CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Update
    @PaymentId        INT,
    @FileId           INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(300)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100)  = NULL,
    @SizeBytes        INT            = NULL,
    @Content          VARBINARY(MAX) = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; its files can no longer be changed.', 1;
    DECLARE @Old NVARCHAR(255), @OldType INT;
    SELECT @Old = FileName, @OldType = AttachmentTypeId FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
    IF @Old IS NULL THROW 73006, 'File not found.', 1;
    IF @FileName IS NULL THROW 73000, 'File name is required.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId AND AppliesTo = N'Payment'
                                                     AND (IsActive = 1 OR @AttachmentTypeId = @OldType))
        THROW 73000, 'Attachment type not found, inactive, or not one for payments.', 1;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 73000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE purchase.PaymentFiles
    SET AttachmentTypeId = @AttachmentTypeId, Note = @Note, FileName = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @FileId AND PaymentId = @PaymentId;
    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
    VALUES (@PaymentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                             + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Delete
    @PaymentId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    -- (49) a draft or a posted payment; a reversed one is closed. Every removal is in the payment's audit.
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; its files can no longer be removed.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId);
    IF @Name IS NULL THROW 73006, 'File not found.', 1;

    DELETE FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@PaymentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 5. Container documents */

/* One upload may be shared by several containers (attached to them together). @AllShared = 1 edits the
   upload for every one of them, like deleting it everywhere; 0 edits this container's attachment only -
   and a new file then becomes this container's own copy, leaving the others on the old one. */
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_Update
    @Id               INT,
    @AllShared        BIT            = 0,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(300)  = NULL,
    @DocumentDate     DATE           = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100)  = NULL,
    @SizeBytes        INT            = NULL,
    @Content          VARBINARY(MAX) = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    SET @AllShared = ISNULL(@AllShared, 0);

    DECLARE @FileId INT, @Old NVARCHAR(255);
    SELECT @FileId = a.FileId, @Old = f.FileName
    FROM logistics.ContainerAttachments a INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
    IF @FileId IS NULL THROW 70006, 'Attachment not found.', 1;
    IF @FileName IS NULL THROW 70000, 'The file name is required.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId)
        THROW 70000, 'Attachment type not found.', 1;
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
END
GO

PRINT 'Script 49 applied: attachments can be edited and deleted everywhere.';
GO

SET NOEXEC OFF;
GO
