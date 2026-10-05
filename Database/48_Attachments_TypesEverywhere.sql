/* =====================================================================================
   Inventory_Shipment - 48: ATTACHMENT TYPES EVERYWHERE (prompt 40 A1)

   Every file attached to a document now has a TYPE (masterdata.AttachmentTypes: Category / SubType), a document date
   and a note, as the containers' attachments always had. An attachment type says what it is USED FOR: the document
   kinds whose upload dialogs offer it (masterdata.AttachmentTypeUsages).

   The attachment features of the system (found in Schema.sql and the controllers)
     Document kind                  Table                              Procedures (Add / Get = download / Delete)    Endpoint
     Containers, movements, charges logistics.ContainerAttachments     logistics.usp_ContainerAttachment_*            api/logistics/containers/attachments
                                    + logistics.Files                  (the file kept once, shared by containers)
     Purchase orders / invoices /   purchase.PurchaseDocumentFiles     purchase.usp_PurchaseDocumentFile_*            api/purchase/documents/{id}/files
       returns (PO, PINV, PRET)
     Sales orders / invoices /      sales.SalesDocumentFiles           sales.usp_SalesDocumentFile_*                  api/sales/invoices/{id}/files
       returns (SO, SINV, SRET)
     Customer receipts (RCPT)       sales.ReceiptFiles                 sales.usp_ReceiptFile_*                        api/sales/receipts/{id}/files
     Inventory In / Out             inventory.StockDocumentFiles       inventory.usp_StockDocumentFile_*              api/inventory/stock-documents/{id}/files
       (INV_IN, INV_OUT)
   Left as they are: logistics.ContainerFiles (the model of script 24, no longer written, no procedure uses it for an
   upload any more) and inventory.ItemFiles (an item's picture and data sheets: an item is not a document, it has no
   document kind).

   Used for
     DocumentKind = 'CONTAINER' (containers, their movements and charges) or the document type code of the document
     (PO, PINV, PRET, SO, SINV, SRET, RCPT, INV_IN, INV_OUT) - masterdata.fn_AttachmentDocumentKinds lists them.
     First run only (the usages table empty): every type keeps the list it was on - AppliesTo 'Logistics' ->
     CONTAINER, AppliesTo 'Receipt' -> RCPT (the container pages and the receipt page offer what they offered); the
     type "Other" (the existing Other / Other, else General / Other) is used for every kind; and a few common types
     are added where missing (see section 2). AppliesTo stays (additive only) but no procedure reads it any more.

   Files
     Purchase, sales and stock document files gain AttachmentTypeId, DocumentDate and Note (NVARCHAR(500)); receipt
     files gain DocumentDate. Existing files without a type get "Other" (the containers' too), then AttachmentTypeId
     is NOT NULL on the four document tables. The notes of receipt and container files widen to NVARCHAR(500).

   Procedures
     masterdata.usp_AttachmentType_CheckForKind (new): THE check of every upload and edit - a type is required
       ("Choose the attachment type."), active, and used for the kind ("The attachment type {name} is not used for
       {kind}."), raised with the module's own error number.
     Add (re-created from the current bodies) + @AttachmentTypeId, @DocumentDate, @Note: purchase.usp_PurchaseDocument
       File_Add, sales.usp_SalesDocumentFile_Add, inventory.usp_StockDocumentFile_Add, sales.usp_ReceiptFile_Add
       (@DocumentDate; its type was optional and checked on AppliesTo), logistics.usp_ContainerAttachment_Add (its type
       was optional).
     Update (new, type / date / note of a file, the same checks; answers the file's row) and List (new, the files of
       a document with their type, date and note, @AttachmentTypeId filter): one each per table above.
     masterdata.usp_AttachmentType_Search / _Get: + UsedFor (the kinds, comma separated), Search + @DocumentKind;
       _Lookup: + @DocumentKind (its @AppliesTo still answers as before: Logistics = CONTAINER, Receipt = RCPT);
       _Save: + @UsedFor (comma separated kinds, at least one; NULL = unchanged); _Delete: refuses a type any file uses;
       _DocumentKinds (new): the kinds, code and name.

   Errors (new): 62011 inventory, 64017 sales documents, 65032 purchase, 70017 containers, 71016 receipts - the
   attachment type is missing, inactive, unknown or not used for the document's kind. Master data: 69000 validation
   (kinds), 69014 a used type cannot be deleted (as before).

   Requires the receipts (scripts 35-36: sales.ReceiptFiles.AttachmentTypeId, AttachmentTypes.AppliesTo) and script 27.
   Idempotent, additive: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'masterdata.AttachmentTypes', N'AppliesTo') IS NULL
   OR COL_LENGTH(N'sales.ReceiptFiles', N'AttachmentTypeId') IS NULL
   OR OBJECT_ID(N'logistics.ContainerAttachments', N'U') IS NULL
   OR OBJECT_ID(N'purchase.PurchaseDocumentFiles', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 27, 35 and 36 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The document kinds */

-- The kinds an attachment type can be used for. Name is the label of the pages, Noun the words of the messages.
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
             (N'INV_IN',    N'Inventory In',      N'Inventory In documents',  90),
             (N'INV_OUT',   N'Inventory Out',     N'Inventory Out documents', 100)) k (Code, Name, Noun, SortOrder);
GO

/* ================================================================== 2. Used for: the table and its first run */

IF OBJECT_ID(N'masterdata.AttachmentTypeUsages', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.AttachmentTypeUsages
    (
        AttachmentTypeId INT          NOT NULL,
        DocumentKind     NVARCHAR(20) NOT NULL,   -- CONTAINER or a document type code (masterdata.fn_AttachmentDocumentKinds)
        CONSTRAINT PK_AttachmentTypeUsages PRIMARY KEY CLUSTERED (AttachmentTypeId, DocumentKind),
        CONSTRAINT FK_AttachmentTypeUsages_Type FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id)
    );
    CREATE NONCLUSTERED INDEX IX_AttachmentTypeUsages_Kind ON masterdata.AttachmentTypeUsages (DocumentKind);
    PRINT 'Created masterdata.AttachmentTypeUsages';
END
GO

-- First run only (no usage yet): the lists the pages had, "Other" for every kind, the common types. Never again:
-- a kind taken off a type by hand stays off.
IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages)
BEGIN
    INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
    SELECT Id, CASE WHEN AppliesTo = N'Receipt' THEN N'RCPT' ELSE N'CONTAINER' END FROM masterdata.AttachmentTypes;

    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE SubType = N'Other' AND Category IN (N'Other', N'General'))
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, AppliesTo) VALUES (N'General', N'Other', 999, N'Logistics');
    DECLARE @Other INT = (SELECT TOP (1) Id FROM masterdata.AttachmentTypes
                          WHERE SubType = N'Other' AND Category IN (N'Other', N'General')
                          ORDER BY CASE Category WHEN N'Other' THEN 0 ELSE 1 END, Id);
    INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
    SELECT @Other, k.Code FROM masterdata.fn_AttachmentDocumentKinds() k
    WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = @Other AND u.DocumentKind = k.Code);

    -- the common types: created when missing, and used for these kinds (an existing type of the same name keeps its
    -- kinds and gains these)
    DECLARE @Seed TABLE (Category NVARCHAR(30), SubType NVARCHAR(60), SortOrder INT, Kinds NVARCHAR(200));
    INSERT INTO @Seed VALUES
        (N'Purchase', N'Proforma Invoice',      50,  N'PO'),
        (N'Purchase', N'Quotation',             52,  N'PO'),
        (N'Purchase', N'Order Confirmation',    54,  N'PO'),
        (N'Purchase', N'Commercial Invoice',    30,  N'PINV'),
        (N'Purchase', N'Packing List',          40,  N'PINV'),
        (N'Shipping', N'Bill of Lading',        60,  N'PINV'),
        (N'Customs',  N'Certificate of Origin', 105, N'PINV,CONTAINER'),
        (N'Shipping', N'Insurance Certificate', 82,  N'PINV,CONTAINER'),
        (N'Returns',  N'Return Note',           200, N'PRET,SRET'),
        (N'Returns',  N'Credit Note',           210, N'PRET,SRET'),
        (N'Sales',    N'Customer Order',        300, N'SO,SINV'),
        (N'Delivery', N'Delivery Note',         310, N'SINV,SRET,INV_IN,INV_OUT'),
        (N'Payment',  N'Payment Proof',         320, N'SINV,RCPT');
    INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, AppliesTo)
    SELECT s.Category, s.SubType, s.SortOrder, N'Logistics' FROM @Seed s
    WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes t WHERE t.Category = s.Category AND t.SubType = s.SubType);
    INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
    SELECT DISTINCT t.Id, LTRIM(RTRIM(k.value))
    FROM @Seed s
    INNER JOIN masterdata.AttachmentTypes t ON t.Category = s.Category AND t.SubType = s.SubType
    CROSS APPLY STRING_SPLIT(s.Kinds, N',') k
    WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = t.Id AND u.DocumentKind = LTRIM(RTRIM(k.value)));
    PRINT 'Attachment types: kinds of the existing types, "Other" for every kind, common types added.';
END
GO

/* ================================================================== 3. The files: type, date, note */

IF COL_LENGTH(N'purchase.PurchaseDocumentFiles', N'AttachmentTypeId') IS NULL
    ALTER TABLE purchase.PurchaseDocumentFiles ADD AttachmentTypeId INT NULL
        CONSTRAINT FK_PurchaseDocumentFiles_Type FOREIGN KEY REFERENCES masterdata.AttachmentTypes (Id);
IF COL_LENGTH(N'purchase.PurchaseDocumentFiles', N'DocumentDate') IS NULL ALTER TABLE purchase.PurchaseDocumentFiles ADD DocumentDate DATE NULL;
IF COL_LENGTH(N'purchase.PurchaseDocumentFiles', N'Note') IS NULL ALTER TABLE purchase.PurchaseDocumentFiles ADD Note NVARCHAR(500) NULL;
IF COL_LENGTH(N'sales.SalesDocumentFiles', N'AttachmentTypeId') IS NULL
    ALTER TABLE sales.SalesDocumentFiles ADD AttachmentTypeId INT NULL
        CONSTRAINT FK_SalesDocumentFiles_Type FOREIGN KEY REFERENCES masterdata.AttachmentTypes (Id);
IF COL_LENGTH(N'sales.SalesDocumentFiles', N'DocumentDate') IS NULL ALTER TABLE sales.SalesDocumentFiles ADD DocumentDate DATE NULL;
IF COL_LENGTH(N'sales.SalesDocumentFiles', N'Note') IS NULL ALTER TABLE sales.SalesDocumentFiles ADD Note NVARCHAR(500) NULL;
IF COL_LENGTH(N'inventory.StockDocumentFiles', N'AttachmentTypeId') IS NULL
    ALTER TABLE inventory.StockDocumentFiles ADD AttachmentTypeId INT NULL
        CONSTRAINT FK_StockDocumentFiles_Type FOREIGN KEY REFERENCES masterdata.AttachmentTypes (Id);
IF COL_LENGTH(N'inventory.StockDocumentFiles', N'DocumentDate') IS NULL ALTER TABLE inventory.StockDocumentFiles ADD DocumentDate DATE NULL;
IF COL_LENGTH(N'inventory.StockDocumentFiles', N'Note') IS NULL ALTER TABLE inventory.StockDocumentFiles ADD Note NVARCHAR(500) NULL;
IF COL_LENGTH(N'sales.ReceiptFiles', N'DocumentDate') IS NULL ALTER TABLE sales.ReceiptFiles ADD DocumentDate DATE NULL;
-- one note length for every file: the receipts' and the containers' widen
IF COL_LENGTH(N'sales.ReceiptFiles', N'Note') < 1000 ALTER TABLE sales.ReceiptFiles ALTER COLUMN Note NVARCHAR(500) NULL;
IF COL_LENGTH(N'logistics.ContainerAttachments', N'Note') < 1000 ALTER TABLE logistics.ContainerAttachments ALTER COLUMN Note NVARCHAR(500) NULL;
GO

-- Files without a type are "Other" (first run; a later run finds none).
DECLARE @Other INT = (SELECT TOP (1) Id FROM masterdata.AttachmentTypes
                      WHERE SubType = N'Other' AND Category IN (N'Other', N'General')
                      ORDER BY CASE Category WHEN N'Other' THEN 0 ELSE 1 END, Id);
UPDATE purchase.PurchaseDocumentFiles  SET AttachmentTypeId = @Other WHERE AttachmentTypeId IS NULL;
UPDATE sales.SalesDocumentFiles        SET AttachmentTypeId = @Other WHERE AttachmentTypeId IS NULL;
UPDATE inventory.StockDocumentFiles    SET AttachmentTypeId = @Other WHERE AttachmentTypeId IS NULL;
UPDATE sales.ReceiptFiles              SET AttachmentTypeId = @Other WHERE AttachmentTypeId IS NULL;
UPDATE logistics.ContainerAttachments  SET AttachmentTypeId = @Other WHERE AttachmentTypeId IS NULL;
GO

-- Then required on the document tables (the containers' column stays as it is: script 27's).
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'purchase.PurchaseDocumentFiles') AND name = N'AttachmentTypeId' AND is_nullable = 1)
    ALTER TABLE purchase.PurchaseDocumentFiles ALTER COLUMN AttachmentTypeId INT NOT NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'sales.SalesDocumentFiles') AND name = N'AttachmentTypeId' AND is_nullable = 1)
    ALTER TABLE sales.SalesDocumentFiles ALTER COLUMN AttachmentTypeId INT NOT NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'inventory.StockDocumentFiles') AND name = N'AttachmentTypeId' AND is_nullable = 1)
    ALTER TABLE inventory.StockDocumentFiles ALTER COLUMN AttachmentTypeId INT NOT NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'sales.ReceiptFiles') AND name = N'AttachmentTypeId' AND is_nullable = 1)
    ALTER TABLE sales.ReceiptFiles ALTER COLUMN AttachmentTypeId INT NOT NULL;
GO

/* ================================================================== 4. The check of every upload and edit */

-- One place for the rule: a type is chosen, exists, is active and is used for the document's kind. @ErrorNumber is
-- the module's (62011, 64017, 65032, 70017, 71016), so each module classifies the refusal as its own.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_CheckForKind
    @AttachmentTypeId INT,
    @DocumentKind     NVARCHAR(20),
    @ErrorNumber      INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Msg NVARCHAR(400), @Name NVARCHAR(60), @Active BIT;
    IF @AttachmentTypeId IS NULL THROW @ErrorNumber, 'Choose the attachment type.', 1;
    SELECT @Name = SubType, @Active = IsActive FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId;
    IF @Name IS NULL THROW @ErrorNumber, 'The attachment type was not found.', 1;
    IF @Active = 0
    BEGIN
        SET @Msg = N'The attachment type ' + @Name + N' is inactive.';
        THROW @ErrorNumber, @Msg, 1;
    END
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages WHERE AttachmentTypeId = @AttachmentTypeId AND DocumentKind = @DocumentKind)
    BEGIN
        SET @Msg = N'The attachment type ' + @Name + N' is not used for '
                 + ISNULL((SELECT Noun FROM masterdata.fn_AttachmentDocumentKinds() WHERE Code = @DocumentKind), @DocumentKind) + N'.';
        THROW @ErrorNumber, @Msg, 1;
    END
END
GO

/* ================================================================== 5. Purchase documents (PO, PINV, PRET) */

-- Re-created (48) from the body of script 21: + the type (required, used for the document's kind), date and note.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT,
    @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId) THROW 65006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 65000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 65000, 'The file is empty.', 1;
    DECLARE @Kind NVARCHAR(20) = (SELECT dt.Code FROM purchase.PurchaseDocuments d
                                  INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId);
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 65032;

    INSERT INTO purchase.PurchaseDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy, AttachmentTypeId, DocumentDate, Note)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId, @AttachmentTypeId, @DocumentDate,
            NULLIF(LTRIM(RTRIM(@Note)), N''));
    SET @NewId = SCOPE_IDENTITY();
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

-- The files of a document (one with @FileId), newest first; IsOther = still typed "Other".
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_List
    @DocumentId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @DocumentId AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

-- Type, date and note of a file (the same checks as the upload); answers the file's row.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255), @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Name = f.FileName, @Kind = dt.Code
    FROM purchase.PurchaseDocumentFiles f
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 65032;

    UPDATE purchase.PurchaseDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileUpdated', @Name, @UserId);
    EXEC purchase.usp_PurchaseDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END
GO

/* ================================================================== 6. Sales documents (SO, SINV, SRET) */

-- Re-created (48) from the body of script 17: + the type (required, used for the document's kind), date and note.
CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT,
    @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @DocumentId) THROW 64006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 64000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 64000, 'The file is empty.', 1;
    DECLARE @Kind NVARCHAR(20) = (SELECT dt.Code FROM sales.SalesDocuments d
                                  INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId);
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 64017;

    INSERT INTO sales.SalesDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy, AttachmentTypeId, DocumentDate, Note)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId, @AttachmentTypeId, @DocumentDate,
            NULLIF(LTRIM(RTRIM(@Note)), N''));
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_List
    @DocumentId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM sales.SalesDocumentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @DocumentId AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255), @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Name = f.FileName, @Kind = dt.Code
    FROM sales.SalesDocumentFiles f
    INNER JOIN sales.SalesDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 64017;

    UPDATE sales.SalesDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileUpdated', @Name, @UserId);
    EXEC sales.usp_SalesDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END
GO

/* ================================================================== 7. Inventory In / Out (INV_IN, INV_OUT) */

-- Re-created (48) from the body of script 15: + the type (required, used for the document's kind), date and note.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT,
    @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @DocumentId) THROW 62006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 62000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 62000, 'The file is empty.', 1;
    DECLARE @Kind NVARCHAR(20) = (SELECT dt.Code FROM inventory.StockDocuments d
                                  INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId);
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 62011;

    INSERT INTO inventory.StockDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy, AttachmentTypeId, DocumentDate, Note)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId, @AttachmentTypeId, @DocumentDate,
            NULLIF(LTRIM(RTRIM(@Note)), N''));
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_List
    @DocumentId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM inventory.StockDocumentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @DocumentId AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255), @Kind NVARCHAR(20);
    SELECT @DocumentId = f.DocumentId, @Name = f.FileName, @Kind = dt.Code
    FROM inventory.StockDocumentFiles f
    INNER JOIN inventory.StockDocuments d ON d.Id = f.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE f.Id = @Id;
    IF @DocumentId IS NULL THROW 62006, 'File not found.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, @Kind, 62011;

    UPDATE inventory.StockDocumentFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @Id;
    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileUpdated', @Name, @UserId);
    EXEC inventory.usp_StockDocumentFile_List @DocumentId = @DocumentId, @FileId = @Id;
END
GO

/* ================================================================== 8. Customer receipts (RCPT) */

-- Re-created (48) from the body of script 36: the type required and used for receipts (it was optional and checked
-- on AppliesTo), + @DocumentDate; the note takes 500 characters.
CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Add
    @ReceiptId        INT,
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

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- Evidence keeps arriving after a receipt is posted (a bank statement, a payment advice), so a
    -- posted receipt takes files. A reversed one is closed.
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; files can no longer be added.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'RCPT', 71016;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 71000, 'The file is empty.', 1;

    INSERT INTO sales.ReceiptFiles (ReceiptId, AttachmentTypeId, Note, DocumentDate, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@ReceiptId, @AttachmentTypeId, @Note, @DocumentDate, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileAdded', @FileName, @UserId);
END
GO

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_List
    @ReceiptId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.ReceiptId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM sales.ReceiptFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ReceiptId = @ReceiptId AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Update
    @ReceiptId INT, @FileId INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(255), @Status TINYINT;
    SELECT @Name = f.FileName, @Status = r.Status
    FROM sales.ReceiptFiles f INNER JOIN sales.Receipts r ON r.Id = f.ReceiptId
    WHERE f.Id = @FileId AND f.ReceiptId = @ReceiptId;
    IF @Name IS NULL THROW 71006, 'File not found.', 1;
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; its files can no longer be changed.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'RCPT', 71016;

    UPDATE sales.ReceiptFiles
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @FileId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileUpdated', @Name, @UserId);
    EXEC sales.usp_ReceiptFile_List @ReceiptId = @ReceiptId, @FileId = @FileId;
END
GO

/* ================================================================== 9. Containers (CONTAINER) */

-- Re-created (48) from the body of script 27: the type required and used for containers (it was optional); the note
-- takes 500 characters.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_Add
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementId       INT            = NULL,
    @ChargeId         INT            = NULL,
    @AttachmentTypeId INT            = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @Note             NVARCHAR(500)  = NULL,
    @DocumentDate     DATE           = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds;
    -- a charge alone is enough: its container is taken
    IF NOT EXISTS (SELECT 1 FROM @Ids) AND @ChargeId IS NOT NULL
        INSERT INTO @Ids (Id) SELECT ContainerId FROM logistics.ContainerCharges WHERE Id = @ChargeId;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one container.', 1;
    IF @FileName IS NULL THROW 70000, 'The file name is required.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 OR @Content IS NULL THROW 70000, 'The file is empty.', 1;
    -- (48) the type is required, active and used for containers
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'CONTAINER', 70017;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 70006, 'A selected container no longer exists.', 1;
    IF @MovementId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId)
        THROW 70006, 'Movement not found.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @MovementId IS NOT NULL
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not part of this movement.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = x.Id)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @GroupOfCharge UNIQUEIDENTIFIER = NULL;
    IF @ChargeId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @ChargeId) THROW 70006, 'Charge not found.', 1;
        SELECT @GroupOfCharge = GroupId FROM logistics.ContainerCharges WHERE Id = @ChargeId;
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' has no charge of this group.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = x.Id AND (ch.Id = @ChargeId OR (@GroupOfCharge IS NOT NULL AND ch.GroupId = @GroupOfCharge)))
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @Group UNIQUEIDENTIFIER = CASE WHEN (SELECT COUNT(*) FROM @Ids) > 1 THEN NEWID() END;
    DECLARE @FileId INT;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO logistics.Files (FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@FileName, ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @FileId = SCOPE_IDENTITY();

        INSERT INTO logistics.ContainerAttachments (ContainerId, MovementId, ChargeId, AttachmentTypeId, FileId, Note, DocumentDate, GroupId, CreatedBy)
        SELECT x.Id, @MovementId,
               (SELECT TOP (1) ch.Id FROM logistics.ContainerCharges ch
                WHERE ch.ContainerId = x.Id AND (ch.Id = @ChargeId OR (@GroupOfCharge IS NOT NULL AND ch.GroupId = @GroupOfCharge))
                ORDER BY CASE WHEN ch.Id = @ChargeId THEN 0 ELSE 1 END, ch.Id),
               @AttachmentTypeId, @FileId, @Note, @DocumentDate, @Group, @UserId
        FROM @Ids x;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.Id, N'Updated', LEFT(N'Attachment added: ' + @FileName
                                      + ISNULL(N' (movement ' + (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId) + N')', N''), 500), @UserId
        FROM @Ids x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.FileId, a.MovementId, a.ChargeId
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId
    WHERE a.FileId = @FileId
    ORDER BY c.ContainerRef;
END
GO

-- The attachments of a container (or of one movement's containers, or one attachment), with their type, newest first.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_List
    @ContainerId INT = NULL, @MovementId INT = NULL, @AttachmentTypeId INT = NULL, @Id INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.ContainerId, c.ContainerRef, a.MovementId, m.MovementNo, a.ChargeId, a.FileId, f.FileName, f.ContentType, f.SizeBytes,
           a.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.Id IS NULL OR (t.SubType = N'Other' AND t.Category IN (N'Other', N'General')) THEN 1 ELSE 0 END AS BIT),
           a.DocumentDate, a.Note, a.GroupId,
           SharedWith = (SELECT COUNT(*) FROM logistics.ContainerAttachments s WHERE s.FileId = a.FileId AND s.Id <> a.Id),
           a.CreatedAtUtc, a.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = a.AttachmentTypeId
    LEFT JOIN logistics.Movements m ON m.Id = a.MovementId
    LEFT JOIN security.Users u ON u.Id = a.CreatedBy
    WHERE (@ContainerId IS NULL OR a.ContainerId = @ContainerId) AND (@MovementId IS NULL OR a.MovementId = @MovementId)
      AND (@AttachmentTypeId IS NULL OR a.AttachmentTypeId = @AttachmentTypeId) AND (@Id IS NULL OR a.Id = @Id)
      AND (@ContainerId IS NOT NULL OR @MovementId IS NOT NULL OR @Id IS NOT NULL)
    ORDER BY a.CreatedAtUtc DESC, a.Id DESC;
END
GO

-- Type, date and note of one attachment record (the same checks as the upload); answers its row.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ContainerId INT, @Name NVARCHAR(255);
    SELECT @ContainerId = a.ContainerId, @Name = f.FileName
    FROM logistics.ContainerAttachments a INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
    IF @ContainerId IS NULL THROW 70006, 'Attachment not found.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'CONTAINER', 70017;

    UPDATE logistics.ContainerAttachments
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    VALUES (@ContainerId, N'Updated', LEFT(N'Attachment changed: ' + @Name, 500), @UserId);
    EXEC logistics.usp_ContainerAttachment_List @Id = @Id;
END
GO

/* ================================================================== 10. Master data: attachment types */

-- The document kinds, for the "Used for" lists of the pages (api/masterdata/attachment-types/document-kinds).
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_DocumentKinds
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Code, Name FROM masterdata.fn_AttachmentDocumentKinds() ORDER BY SortOrder;
END
GO

-- Re-created (48) from the body of script 36: the list of a document kind (@DocumentKind); @AppliesTo, which the
-- pages written before still pass, answers as before (Logistics = containers, Receipt = receipts).
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly   BIT          = 1,
    @IncludeId    INT          = NULL,
    @AppliesTo    NVARCHAR(12) = N'Logistics',
    @DocumentKind NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @DocumentKind = ISNULL(NULLIF(LTRIM(RTRIM(@DocumentKind)), N''),
                               CASE WHEN LTRIM(RTRIM(@AppliesTo)) = N'Receipt' THEN N'RCPT' ELSE N'CONTAINER' END);
    SELECT a.Id, a.Category, a.SubType, DisplayName = a.Category + N' / ' + a.SubType, a.SortOrder, a.IsActive
    FROM masterdata.AttachmentTypes a
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = @DocumentKind)
           OR a.Id = @IncludeId)
    ORDER BY a.SortOrder, a.Category, a.SubType;
END
GO

-- Re-created (48) from the body of script 36: + UsedFor (the kinds, comma separated) and the @DocumentKind filter.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Search
    @Search        NVARCHAR(100) = NULL,
    @Category      NVARCHAR(30)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'SortOrder',   -- SortOrder | Category | SubType | IsActive
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10,
    @DocumentKind  NVARCHAR(20)  = NULL            -- (48) the types used for this kind
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @DocumentKind = NULLIF(LTRIM(RTRIM(@DocumentKind)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'SortOrder', N'Category', N'SubType', N'IsActive') SET @SortColumn = N'SortOrder';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.SortOrder, a.IsActive,
           UsedFor = (SELECT STRING_AGG(k.Code, N',') WITHIN GROUP (ORDER BY k.SortOrder)
                      FROM masterdata.AttachmentTypeUsages u
                      INNER JOIN masterdata.fn_AttachmentDocumentKinds() k ON k.Code = u.DocumentKind
                      WHERE u.AttachmentTypeId = a.Id),
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.AttachmentTypes a
    WHERE (@Search IS NULL OR a.Category LIKE N'%' + @Search + N'%' OR a.SubType LIKE N'%' + @Search + N'%')
      AND (@Category IS NULL OR a.Category = @Category)
      AND (@IsActive IS NULL OR a.IsActive = @IsActive)
      AND (@DocumentKind IS NULL OR EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = @DocumentKind))
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'Category' THEN a.Category WHEN N'SubType' THEN a.SubType END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'Category' THEN a.Category WHEN N'SubType' THEN a.SubType END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'SortOrder' THEN a.SortOrder END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'SortOrder' THEN a.SortOrder END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END DESC,
        a.SortOrder, a.Category, a.SubType
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Re-created (48) from the body of script 36: + UsedFor.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.SortOrder, a.IsActive,
           UsedFor = (SELECT STRING_AGG(k.Code, N',') WITHIN GROUP (ORDER BY k.SortOrder)
                      FROM masterdata.AttachmentTypeUsages u
                      INNER JOIN masterdata.fn_AttachmentDocumentKinds() k ON k.Code = u.DocumentKind
                      WHERE u.AttachmentTypeId = a.Id),
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion
    FROM masterdata.AttachmentTypes a WHERE a.Id = @Id;
END
GO

-- Re-created (48) from the body of script 36: + @UsedFor - the kinds, comma separated (CONTAINER,PO,PINV...), at
-- least one; NULL = unchanged on an update, and on an insert the kind of @AppliesTo (Receipt = RCPT, else CONTAINER).
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
    IF @AppliesTo IS NOT NULL AND @AppliesTo NOT IN (N'Logistics', N'Receipt') THROW 69000, 'Applies to must be Logistics or Receipt.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND (@Id IS NULL OR Id <> @Id))
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
        INSERT INTO @Kinds (Code) VALUES (CASE WHEN @AppliesTo = N'Receipt' THEN N'RCPT' ELSE N'CONTAINER' END);

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

-- Re-created (48) from the body of script 36: refused while ANY file uses the type (every attachment table).
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

/* ================================================================== 11. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'masterdata.fn_AttachmentDocumentKinds'), (N'masterdata.AttachmentTypeUsages'), (N'masterdata.usp_AttachmentType_CheckForKind'),
             (N'purchase.usp_PurchaseDocumentFile_Add'), (N'purchase.usp_PurchaseDocumentFile_List'), (N'purchase.usp_PurchaseDocumentFile_Update'),
             (N'sales.usp_SalesDocumentFile_Add'), (N'sales.usp_SalesDocumentFile_List'), (N'sales.usp_SalesDocumentFile_Update'),
             (N'inventory.usp_StockDocumentFile_Add'), (N'inventory.usp_StockDocumentFile_List'), (N'inventory.usp_StockDocumentFile_Update'),
             (N'sales.usp_ReceiptFile_Add'), (N'sales.usp_ReceiptFile_List'), (N'sales.usp_ReceiptFile_Update'),
             (N'logistics.usp_ContainerAttachment_Add'), (N'logistics.usp_ContainerAttachment_List'), (N'logistics.usp_ContainerAttachment_Update'),
             (N'masterdata.usp_AttachmentType_Lookup'), (N'masterdata.usp_AttachmentType_Search'), (N'masterdata.usp_AttachmentType_Get'),
             (N'masterdata.usp_AttachmentType_Save'), (N'masterdata.usp_AttachmentType_Delete'), (N'masterdata.usp_AttachmentType_DocumentKinds')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 24: 1 function, 1 table, 22 procedures

-- Files by type, per attachment table.
SELECT Files = x.TableName, Type = ISNULL(t.Category + N' / ' + t.SubType, N'(none)'), N = COUNT(*)
FROM (SELECT N'purchase.PurchaseDocumentFiles' AS TableName, AttachmentTypeId FROM purchase.PurchaseDocumentFiles
      UNION ALL SELECT N'sales.SalesDocumentFiles', AttachmentTypeId FROM sales.SalesDocumentFiles
      UNION ALL SELECT N'inventory.StockDocumentFiles', AttachmentTypeId FROM inventory.StockDocumentFiles
      UNION ALL SELECT N'sales.ReceiptFiles', AttachmentTypeId FROM sales.ReceiptFiles
      UNION ALL SELECT N'logistics.ContainerAttachments', AttachmentTypeId FROM logistics.ContainerAttachments) x
LEFT JOIN masterdata.AttachmentTypes t ON t.Id = x.AttachmentTypeId
GROUP BY x.TableName, t.Category, t.SubType
ORDER BY x.TableName, Type;

-- The types and what they are used for.
SELECT a.Id, a.Category, a.SubType, a.IsActive,
       UsedFor = (SELECT STRING_AGG(k.Code, N',') WITHIN GROUP (ORDER BY k.SortOrder)
                  FROM masterdata.AttachmentTypeUsages u INNER JOIN masterdata.fn_AttachmentDocumentKinds() k ON k.Code = u.DocumentKind
                  WHERE u.AttachmentTypeId = a.Id)
FROM masterdata.AttachmentTypes a
ORDER BY a.SortOrder, a.Category, a.SubType;

PRINT 'Script 48 applied: attachment types used for every document kind; every file has a type, a date and a note.';
GO

SET NOEXEC OFF;
GO
