SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   Inventory_Shipment - 55: ATTACHMENTS - ONE EDIT FOR EVERY FILE, PAYMENTS ON THE "USED FOR" LIST

   Two attachment features were built side by side and are merged here:
     - script 49 (edit and delete everywhere): a file's NAME and, optionally, a new version of the file in the
       same place in the list - a container's for this container only or for every container sharing the upload;
       receipt and payment files their type and note too;
     - script 52 (attachment types everywhere): every file has a TYPE used for the document's kind
       (masterdata.AttachmentTypeUsages), a document date and a note, edited with the upload's checks.
   Both wrote the same seven procedures (the *File_Update ones, usp_ContainerAttachment_Update,
   usp_AttachmentType_Save / _Delete), so whichever ran last silently replaced the other's. From here ONE edit
   does both:

     ..._Update  @AttachmentTypeId, @DocumentDate, @Note - the upload's checks: a type is required, active and used
                 for the document's kind, except that a file may keep the type it has though it was deactivated
                 since; @FileName (NULL keeps it); optionally @ContentType / @SizeBytes / @Content, a new version
                 of the file (NULL keeps the stored one). Audited "old -> new (new file)". Answers the file's row
                 (the List procedure's).
       inventory.usp_StockDocumentFile_Update, sales.usp_SalesDocumentFile_Update,
       purchase.usp_PurchaseDocumentFile_Update, sales.usp_ReceiptFile_Update, purchase.usp_PaymentFile_Update
       (not on a reversed receipt / payment), logistics.usp_ContainerAttachment_Update (+ @AllShared: 1 = every
       container holding the upload; 0 = this record only, and a new name or file then becomes its own copy while
       the others keep the upload as it was).
     inventory.usp_ItemFile_Update stays script 49's: an item's files have no type.

   SUPPLIER PAYMENTS (scripts 46-47) JOIN THE "USED FOR" LIST as the kind PAY: the types of the Payment list are
   used for PAY (once, while no type is), payment files gain DocumentDate, their note takes 500 characters, files
   without a type get the Payment list's "Other / Other", and the type is then required: usp_PaymentFile_Add and
   _Update check it with masterdata.usp_AttachmentType_CheckForKind (error 73013). usp_PaymentFile_List (new)
   lists them like every other family's files.

   Attachment types: names stay unique PER LIST (Category, SubType, AppliesTo - script 46's constraint); _Save
   takes AppliesTo Payment as well as @UsedFor; _Lookup's @AppliesTo = Payment answers PAY; _Delete refuses a type
   that any file of any table uses, payments included.

   Requires scripts 46-49 and 52. Idempotent: re-applied at every API start-up through Schema.sql.
   ================================================================================================== */

IF OBJECT_ID(N'masterdata.usp_AttachmentType_CheckForKind', N'P') IS NULL
   OR OBJECT_ID(N'masterdata.AttachmentTypeUsages', N'U') IS NULL
   OR OBJECT_ID(N'purchase.PaymentFiles', N'U') IS NULL
   OR OBJECT_ID(N'purchase.usp_PaymentFile_Delete', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 46-49 and 52 before script 55.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The document kinds: + supplier payments */

CREATE OR ALTER FUNCTION masterdata.fn_AttachmentDocumentKinds ()
RETURNS TABLE
AS
RETURN
SELECT k.Code, k.Name, k.Noun, k.SortOrder
FROM (VALUES (N'CONTAINER', N'Containers',        N'containers',              10),
             (N'PO',        N'Purchase orders',   N'purchase orders',         20),
             (N'PINV',      N'Purchase invoices', N'purchase invoices',       30),
             (N'PRET',      N'Purchase returns',  N'purchase returns',        40),
             (N'SO',        N'Sales orders',      N'sales orders',            50),
             (N'SINV',      N'Sales invoices',    N'sales invoices',          60),
             (N'SRET',      N'Sales returns',     N'sales returns',           70),
             (N'RCPT',      N'Customer receipts', N'customer receipts',       80),
             (N'PAY',       N'Supplier payments', N'supplier payments',       85),
             (N'INV_IN',    N'Inventory In',      N'Inventory In documents',  90),
             (N'INV_OUT',   N'Inventory Out',     N'Inventory Out documents', 100)) k (Code, Name, Noun, SortOrder);
GO

-- Once, while no type is used for payments: the Payment list (script 46) is what the payment page offered.
IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages WHERE DocumentKind = N'PAY')
BEGIN
    INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
    SELECT Id, N'PAY' FROM masterdata.AttachmentTypes WHERE AppliesTo = N'Payment';
    PRINT 'Attachment types: the Payment list is used for supplier payments (PAY).';
END
GO

/* ================================================================== 2. Payment files: date, note, type required */

IF COL_LENGTH(N'purchase.PaymentFiles', N'DocumentDate') IS NULL ALTER TABLE purchase.PaymentFiles ADD DocumentDate DATE NULL;
IF COL_LENGTH(N'purchase.PaymentFiles', N'Note') < 1000 ALTER TABLE purchase.PaymentFiles ALTER COLUMN Note NVARCHAR(500) NULL;
GO

-- Files without a type are "Other": the one used for payments, else any "Other" (which is then used for payments).
IF EXISTS (SELECT 1 FROM purchase.PaymentFiles WHERE AttachmentTypeId IS NULL)
BEGIN
    DECLARE @Other INT = (SELECT TOP (1) t.Id FROM masterdata.AttachmentTypes t
                          INNER JOIN masterdata.AttachmentTypeUsages u ON u.AttachmentTypeId = t.Id AND u.DocumentKind = N'PAY'
                          WHERE t.SubType = N'Other' AND t.Category IN (N'Other', N'General')
                          ORDER BY CASE t.Category WHEN N'Other' THEN 0 ELSE 1 END, t.Id);
    IF @Other IS NULL
        SET @Other = (SELECT TOP (1) Id FROM masterdata.AttachmentTypes
                      WHERE SubType = N'Other' AND Category IN (N'Other', N'General')
                      ORDER BY CASE AppliesTo WHEN N'Payment' THEN 0 ELSE 1 END, CASE Category WHEN N'Other' THEN 0 ELSE 1 END, Id);
    IF @Other IS NOT NULL
    BEGIN
        UPDATE purchase.PaymentFiles SET AttachmentTypeId = @Other WHERE AttachmentTypeId IS NULL;
        IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages WHERE AttachmentTypeId = @Other AND DocumentKind = N'PAY')
            INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind) VALUES (@Other, N'PAY');
    END
END
GO

IF NOT EXISTS (SELECT 1 FROM purchase.PaymentFiles WHERE AttachmentTypeId IS NULL)
   AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'purchase.PaymentFiles') AND name = N'AttachmentTypeId' AND is_nullable = 1)
    ALTER TABLE purchase.PaymentFiles ALTER COLUMN AttachmentTypeId INT NOT NULL;
GO

/* ================================================================== 3. Purchase, sales and stock documents */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @DocumentId INT, @Old NVARCHAR(255), @OldType INT, @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Old = f.FileName, @OldType = f.AttachmentTypeId, @Kind = dt.Code
    FROM purchase.PurchaseDocumentFiles f
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    -- the type the file has may stay though deactivated since; a new choice is checked as the upload's
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 65032;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 65000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE purchase.PurchaseDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC purchase.usp_PurchaseDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @DocumentId INT, @Old NVARCHAR(255), @OldType INT, @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Old = f.FileName, @OldType = f.AttachmentTypeId, @Kind = dt.Code
    FROM sales.SalesDocumentFiles f
    INNER JOIN sales.SalesDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 64017;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 64000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE sales.SalesDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC sales.usp_SalesDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @DocumentId INT, @Old NVARCHAR(255), @OldType INT, @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Old = f.FileName, @OldType = f.AttachmentTypeId, @Kind = dt.Code
    FROM inventory.StockDocumentFiles f
    INNER JOIN inventory.StockDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 62006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 62011;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 62000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE inventory.StockDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @Id;
    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@DocumentId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                              + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC inventory.usp_StockDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END
GO

/* ================================================================== 4. Customer receipts (RCPT) */

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Update
    @ReceiptId INT, @FileId INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL,
    @FileName NVARCHAR(255) = NULL, @ContentType NVARCHAR(100) = NULL, @SizeBytes INT = NULL, @Content VARBINARY(MAX) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be changed.', 1;
    DECLARE @Old NVARCHAR(255), @OldType INT;
    SELECT @Old = FileName, @OldType = AttachmentTypeId FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    IF @Old IS NULL THROW 71006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'RCPT', 71016;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 71000, 'The file is empty.', 1;

    BEGIN TRANSACTION;
    UPDATE sales.ReceiptFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
        FileName    = @FileName,
        ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content     = ISNULL(@Content, Content)
    WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
    VALUES (@ReceiptId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                             + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
    COMMIT TRANSACTION;

    EXEC sales.usp_ReceiptFile_List @ReceiptId = @ReceiptId, @FileId = @FileId;
END
GO

/* ================================================================== 5. Supplier payments (PAY) */

-- Re-created (55) from the body of script 47: the type required and used for payments (it was optional and checked
-- on AppliesTo), + @DocumentDate; the note takes 500 characters.
CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Add
    @PaymentId        INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(500)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT,
    @DocumentDate     DATE           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    -- Evidence keeps arriving after a payment is posted (a SWIFT copy, a bank statement), so a posted payment
    -- takes files. A reversed one is closed.
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; files can no longer be added.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'PAY', 73013;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 73000, 'The file is empty.', 1;

    INSERT INTO purchase.PaymentFiles (PaymentId, AttachmentTypeId, Note, DocumentDate, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@PaymentId, @AttachmentTypeId, @Note, @DocumentDate, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@PaymentId, N'FileAdded', @FileName, @UserId);
END
GO

-- The files of a payment (one with @FileId), newest first, shaped like every other family's.
CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_List
    @PaymentId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.PaymentId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.PaymentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.PaymentId = @PaymentId AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Update
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

/* ================================================================== 6. Container documents (CONTAINER) */

/* One upload may be shared by several containers (attached to them together). @AllShared = 1 edits the
   upload and the type / date / note of every one of them, like deleting it everywhere; 0 edits this
   container's record only - and a new name or file then becomes this container's own copy, leaving the
   others on the upload as it was. Answers the record. */
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_Update
    @Id               INT,
    @AllShared        BIT            = 0,
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
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @AllShared = ISNULL(@AllShared, 0);

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

    EXEC logistics.usp_ContainerAttachment_List @Id = @Id;
END
GO

/* ================================================================== 7. Master data: attachment types */

-- Re-created (55) from the body of script 52: @AppliesTo, which the pages written before still pass, answers as
-- before - Logistics = containers, Receipt = receipts - and Payment = supplier payments.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly   BIT          = 1,
    @IncludeId    INT          = NULL,
    @AppliesTo    NVARCHAR(12) = N'Logistics',
    @DocumentKind NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @DocumentKind = ISNULL(NULLIF(LTRIM(RTRIM(@DocumentKind)), N''),
                               CASE LTRIM(RTRIM(@AppliesTo)) WHEN N'Receipt' THEN N'RCPT' WHEN N'Payment' THEN N'PAY' ELSE N'CONTAINER' END);
    SELECT a.Id, a.Category, a.SubType, DisplayName = a.Category + N' / ' + a.SubType, a.SortOrder, a.IsActive
    FROM masterdata.AttachmentTypes a
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = @DocumentKind)
           OR a.Id = @IncludeId)
    ORDER BY a.SortOrder, a.Category, a.SubType;
END
GO

-- Re-created (55) from the bodies of scripts 46 and 52: @UsedFor (the kinds, comma separated, at least one; NULL =
-- unchanged on an update, and on an insert the kind of @AppliesTo: Receipt = RCPT, Payment = PAY, else CONTAINER);
-- AppliesTo may be Payment; a name is unique within its list (receipts and payments may both have "Cheque / Cheque
-- Copy").
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Save
    @Id         INT          = NULL,
    @Category   NVARCHAR(30),
    @SubType    NVARCHAR(60),
    @SortOrder  INT          = 0,
    @IsActive   BIT          = 1,
    @RowVersion BINARY(8)    = NULL,
    @UserId     INT          = NULL,
    @NewId      INT OUTPUT,
    /* NULL = leave it alone on an update, and Logistics on an insert: every caller that predates the
       column keeps doing exactly what it did. */
    @AppliesTo  NVARCHAR(12) = NULL,
    @UsedFor    NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @SubType = NULLIF(LTRIM(RTRIM(@SubType)), N'');
    SET @AppliesTo = NULLIF(LTRIM(RTRIM(@AppliesTo)), N'');
    IF @Category IS NULL THROW 69000, 'Category is required.', 1;
    IF @SubType IS NULL THROW 69000, 'Sub type is required.', 1;
    IF @AppliesTo IS NOT NULL AND @AppliesTo NOT IN (N'Logistics', N'Receipt', N'Payment') THROW 69000, 'Applies to must be Logistics, Receipt or Payment.', 1;
    DECLARE @List NVARCHAR(12) = COALESCE(@AppliesTo, (SELECT AppliesTo FROM masterdata.AttachmentTypes WHERE Id = @Id), N'Logistics');
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND AppliesTo = @List AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This category and sub type already exist.', 1;

    DECLARE @Kinds TABLE (Code NVARCHAR(20) PRIMARY KEY);
    IF @UsedFor IS NOT NULL
    BEGIN
        INSERT INTO @Kinds (Code)
        SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(@UsedFor, N',') WHERE LTRIM(RTRIM(value)) <> N'';
        IF NOT EXISTS (SELECT 1 FROM @Kinds) THROW 69000, 'Choose at least one document kind the type is used for.', 1;
        DECLARE @Unknown NVARCHAR(20) = (SELECT TOP (1) x.Code FROM @Kinds x
                                         WHERE NOT EXISTS (SELECT 1 FROM masterdata.fn_AttachmentDocumentKinds() k WHERE k.Code = x.Code));
        IF @Unknown IS NOT NULL
        BEGIN
            DECLARE @Msg NVARCHAR(200) = N'Unknown document kind: ' + @Unknown + N'.';
            THROW 69000, @Msg, 1;
        END
    END
    ELSE IF @Id IS NULL
        INSERT INTO @Kinds (Code) VALUES (CASE @AppliesTo WHEN N'Receipt' THEN N'RCPT' WHEN N'Payment' THEN N'PAY' ELSE N'CONTAINER' END);

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, IsActive, AppliesTo, CreatedBy)
            VALUES (@Category, @SubType, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), ISNULL(@AppliesTo, N'Logistics'), @UserId);
            SET @NewId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
            UPDATE masterdata.AttachmentTypes
            SET Category = @Category, SubType = @SubType, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
                AppliesTo = ISNULL(@AppliesTo, AppliesTo),
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            SET @NewId = @Id;
        END

        IF EXISTS (SELECT 1 FROM @Kinds)
        BEGIN
            DELETE FROM masterdata.AttachmentTypeUsages
            WHERE AttachmentTypeId = @NewId AND DocumentKind NOT IN (SELECT Code FROM @Kinds);
            INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
            SELECT @NewId, x.Code FROM @Kinds x
            WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = @NewId AND u.DocumentKind = x.Code);
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (55) from the bodies of scripts 46 and 52: refused while ANY file uses the type, payment files included.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.ReceiptFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.SalesDocumentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PaymentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM inventory.StockDocumentFiles WHERE AttachmentTypeId = @Id)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM masterdata.AttachmentTypeUsages WHERE AttachmentTypeId = @Id;
        DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'masterdata.fn_AttachmentDocumentKinds'),
             (N'purchase.usp_PurchaseDocumentFile_Update'), (N'sales.usp_SalesDocumentFile_Update'), (N'inventory.usp_StockDocumentFile_Update'),
             (N'sales.usp_ReceiptFile_Update'), (N'purchase.usp_PaymentFile_Add'), (N'purchase.usp_PaymentFile_List'),
             (N'purchase.usp_PaymentFile_Update'), (N'logistics.usp_ContainerAttachment_Update'), (N'masterdata.usp_AttachmentType_Lookup'),
             (N'masterdata.usp_AttachmentType_Save'), (N'masterdata.usp_AttachmentType_Delete')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 12: 1 function, 11 procedures

-- The types used for supplier payments.
SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.IsActive
FROM masterdata.AttachmentTypes a
WHERE EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = N'PAY')
ORDER BY a.SortOrder, a.Category, a.SubType;

PRINT 'Script 55 applied: one edit for every attachment (name, file, type, date, note); payments use the Used-for list.';
GO

SET NOEXEC OFF;
GO
