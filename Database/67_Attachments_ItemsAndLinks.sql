SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 67: ATTACHMENTS - ITEMS AND LINKS (prompt 40, documents on every page like Containers)

   The business owner: "check the documents for the pages in the system. it must be as the same way in the
   containers in all the system have a type and popup to specify the properties of this document". Scripts 52 and
   55 gave every document's files a type (used for the document's kind), a document date and a note, with one
   check (masterdata.usp_AttachmentType_CheckForKind) and one edit. What was left, and is done here:

   Rules
     - ITEMS GET DOCUMENTS LIKE EVERY DOCUMENT (the owner's answer: yes). The files of Item Definition are a new
       kind ITEM ("Items"): a type is required, active and used for ITEM ("Choose the attachment type." / "The
       attachment type {name} is not used for items."), plus a document date and a note, checked with the item
       block's error 56009. Script 52 had left items out ("an item is not a document").
         - Used for, on the first run only (the run that adds the column inventory.ItemFiles.AttachmentTypeId): the
           type "Other" (the one the purchase invoices use, else any Other / Other or General / Other, created when
           there is none) is used for ITEM, and these types, category Item, are added where missing and used for
           ITEM: Data Sheet, Specification, Certificate / Homologation, User Manual, Picture. Never again: a kind an
           administrator takes off a type later stays off.
         - The item files from before get "Other" (the one used for items), so the pages ask "Choose a type"; then
           CK_ItemFiles_Type: every row but the item's picture has a type.
         - THE ITEM PICTURE IS UNCHANGED: the row with IsItemImage = 1 has no type, date or note; Add replaces it as
           before without any type check; the list of the item's documents never shows it.
     - A CONTAINER FILE CAN BE RE-LINKED TO A MOVEMENT from its edit: usp_ContainerAttachment_Update takes @MovementId
       with @SetMovement = 1 (NULL = General, not tied to a movement), for this record or, with @AllShared = 1, for
       every container holding the upload; refused with the upload's check and message when a container of those
       records is not on that movement (70000 'Container KTG-... is not part of this movement.'). The charge link
       does not change: a charge's file stays with its charge.
     - A CHARGE'S FILES SAY WHEN THEY ARE STILL TYPED "Other" (logistics.usp_ContainerCharge_Get: + IsOther), so the
       charge drawer can ask for a real type like every other list.
     - UNCHANGED: who may add or delete per family (receipts and payments refuse once reversed, the others in any
       status), the containers' filing (movement / also attach to / charge), nothing requires a file to post, the
       20 MB rule (the API's), Landed Cost Adjustments have no attachments (the owner's answer).

   Objects
     masterdata.fn_AttachmentDocumentKinds (re-created from its current body, script 66: + ITEM)
     masterdata.AttachmentTypes / AttachmentTypeUsages (first run only: "Other" and five Item types used for ITEM)
     inventory.ItemFiles: + AttachmentTypeId (FK_ItemFiles_Type), DocumentDate, Note; CK_ItemFiles_Type
     inventory.usp_ItemFile_Add (re-created from its current body, script 11: + @AttachmentTypeId, @DocumentDate, @Note)
     inventory.usp_ItemFile_Update (re-created from its current body, script 49: + type / date / note, the script 55
       rules; answers the file's row)
     inventory.usp_ItemFile_List (new: an item's documents, the shape of every family's *File_List)
     masterdata.usp_AttachmentType_Delete (re-created from its current body, script 64: + the item files)
     logistics.usp_ContainerAttachment_Update (re-created from its current body, script 55: + @MovementId, @SetMovement)
     logistics.usp_ContainerCharge_Get (re-created from its current body, script 47: + IsOther on its files)

   Errors: 56009 (new, inventory - item definition): the attachment type of an item file is missing, unknown,
   inactive or not used for items. Containers: 70000 / 70006 as the upload's.

   Requires scripts 11, 27, 47, 49, 52, 55, 64 and 66. Idempotent, additive: re-applied at every API start-up through
   Schema.sql, and builds a brand-new empty database (the columns before any procedure that reads them).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.ItemFiles', N'U') IS NULL
   OR OBJECT_ID(N'logistics.ContainerAttachments', N'U') IS NULL
   OR OBJECT_ID(N'logistics.fn_ContainerChargeSettlement') IS NULL
   OR OBJECT_ID(N'masterdata.AttachmentTypeUsages', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.usp_AttachmentType_CheckForKind', N'P') IS NULL
   OR OBJECT_ID(N'purchase.usp_PaymentFile_List', N'P') IS NULL
   OR OBJECT_ID(N'purchase.GoodsReceiptFiles', N'U') IS NULL
   OR COL_LENGTH(N'inventory.DocumentTypes', N'BivacItemsOnly') IS NULL
BEGIN
    RAISERROR ('Run scripts 11, 27, 47, 49, 52, 55, 64 and 66 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The document kinds: + ITEM */

-- Re-created (67) from the body of script 66: + ITEM (Item Definition's documents), after the stock documents.
CREATE OR ALTER FUNCTION masterdata.fn_AttachmentDocumentKinds ()
RETURNS TABLE
AS
RETURN
SELECT k.Code, k.Name, k.Noun, k.SortOrder
FROM (VALUES (N'CONTAINER', N'Containers',        N'containers',              10),
             (N'PO',        N'Purchase orders',   N'purchase orders',         20),
             (N'PINV',      N'Purchase invoices', N'purchase invoices',       30),
             (N'PRET',      N'Purchase returns',  N'purchase returns',        40),
             (N'GRN',       N'Goods receipts',    N'goods receipts',          45),   -- (64)
             (N'SO',        N'Sales orders',      N'sales orders',            50),
             (N'SINV',      N'Sales invoices',    N'sales invoices',          60),
             (N'SRET',      N'Sales returns',     N'sales returns',           70),
             (N'RCPT',      N'Customer receipts', N'customer receipts',       80),
             (N'PAY',       N'Supplier payments', N'supplier payments',       85),
             (N'INV_IN',    N'Inventory In',      N'Inventory In documents',  90),
             (N'INV_OUT',   N'Inventory Out',     N'Inventory Out documents', 100),
             (N'BIV_OUT',   N'BIVAC Out',         N'BIVAC Out documents',     105),   -- (66)
             (N'ITEM',      N'Items',             N'items',                   120)) k (Code, Name, Noun, SortOrder);   -- (67)
GO

/* ================================================================== 2. Item files: the type, and the first run's "Used for" */

-- THE FIRST RUN IS THE ONE THAT ADDS THE TYPE COLUMN: in the same transaction, the types the item pages offer are
-- used for ITEM - "Other" (the one the purchase invoices use, as script 64 picks it; created when there is none at
-- all) and the Item types below, created where missing (an existing type of the same name keeps its kinds and gains
-- ITEM). Never again: a kind an administrator takes off a type later stays off. Both or neither: a failed run
-- leaves no column, and the next start-up tries again.
IF COL_LENGTH(N'inventory.ItemFiles', N'AttachmentTypeId') IS NULL
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        ALTER TABLE inventory.ItemFiles ADD AttachmentTypeId INT NULL   -- NULL only on the item's picture (CK_ItemFiles_Type)
            CONSTRAINT FK_ItemFiles_Type FOREIGN KEY REFERENCES masterdata.AttachmentTypes (Id);

        DECLARE @Other INT = (SELECT TOP (1) t.Id FROM masterdata.AttachmentTypes t
                              WHERE t.SubType = N'Other' AND t.Category IN (N'Other', N'General')
                              ORDER BY CASE WHEN EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u
                                                         WHERE u.AttachmentTypeId = t.Id AND u.DocumentKind = N'PINV') THEN 0 ELSE 1 END,
                                       CASE t.AppliesTo WHEN N'Logistics' THEN 0 ELSE 1 END,
                                       CASE t.Category WHEN N'Other' THEN 0 ELSE 1 END, t.Id);
        IF @Other IS NULL
        BEGIN
            INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, AppliesTo) VALUES (N'General', N'Other', 999, N'Logistics');
            SET @Other = SCOPE_IDENTITY();
        END
        INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
        SELECT @Other, N'ITEM'
        WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = @Other AND u.DocumentKind = N'ITEM');

        DECLARE @Seed TABLE (Category NVARCHAR(30), SubType NVARCHAR(60), SortOrder INT);
        INSERT INTO @Seed (Category, SubType, SortOrder) VALUES
            (N'Item', N'Data Sheet',                 400),
            (N'Item', N'Specification',              410),
            (N'Item', N'Certificate / Homologation', 420),
            (N'Item', N'User Manual',                430),
            (N'Item', N'Picture',                    440);
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, AppliesTo)
        SELECT s.Category, s.SubType, s.SortOrder, N'Logistics' FROM @Seed s
        WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes t WHERE t.Category = s.Category AND t.SubType = s.SubType);
        INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
        SELECT DISTINCT t.Id, N'ITEM'
        FROM @Seed s
        INNER JOIN masterdata.AttachmentTypes t ON t.Category = s.Category AND t.SubType = s.SubType
        WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = t.Id AND u.DocumentKind = N'ITEM');

        COMMIT TRANSACTION;
        PRINT 'Item files: added AttachmentTypeId; attachment types used for items: Other, Data Sheet, Specification, '
              + 'Certificate / Homologation, User Manual, Picture.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    SET XACT_ABORT OFF;
END
GO

IF COL_LENGTH(N'inventory.ItemFiles', N'DocumentDate') IS NULL ALTER TABLE inventory.ItemFiles ADD DocumentDate DATE NULL;           -- the date on the document
IF COL_LENGTH(N'inventory.ItemFiles', N'Note') IS NULL ALTER TABLE inventory.ItemFiles ADD Note NVARCHAR(500) NULL;                 -- every family's note length
GO

/* ================================================================== 3. The item files from before: "Other", then the type is required */

-- The documents uploaded before types existed for items are "Other": the one used for items, else script 52's pick
-- (Other / Other before General / Other), created and used for items when there is none at all. The picture keeps
-- no type. A later run finds nothing to do.
IF EXISTS (SELECT 1 FROM inventory.ItemFiles WHERE IsItemImage = 0 AND AttachmentTypeId IS NULL)
BEGIN
    DECLARE @Other INT = (SELECT TOP (1) t.Id FROM masterdata.AttachmentTypes t
                          WHERE t.SubType = N'Other' AND t.Category IN (N'Other', N'General')
                          ORDER BY CASE WHEN EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u
                                                     WHERE u.AttachmentTypeId = t.Id AND u.DocumentKind = N'ITEM') THEN 0 ELSE 1 END,
                                   CASE t.Category WHEN N'Other' THEN 0 ELSE 1 END, t.Id);
    IF @Other IS NULL
    BEGIN
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, AppliesTo) VALUES (N'General', N'Other', 999, N'Logistics');
        SET @Other = SCOPE_IDENTITY();
        INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind) VALUES (@Other, N'ITEM');
    END

    UPDATE inventory.ItemFiles SET AttachmentTypeId = @Other WHERE IsItemImage = 0 AND AttachmentTypeId IS NULL;
    PRINT 'Item files: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + N' file(s) from before typed "Other".';
END
GO

-- Every row but the item's picture has a type (the column stays nullable for the picture).
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ItemFiles_Type' AND parent_object_id = OBJECT_ID(N'inventory.ItemFiles'))
BEGIN
    ALTER TABLE inventory.ItemFiles WITH CHECK ADD CONSTRAINT CK_ItemFiles_Type CHECK (IsItemImage = 1 OR AttachmentTypeId IS NOT NULL);
    PRINT 'Item files: CK_ItemFiles_Type added (a type on every file but the picture).';
END
GO

/* ================================================================== 4. Item file procedures */

-- Re-created (67) from the body of script 11: a document (@IsItemImage 0) needs a type used for items, and takes a
-- document date and a note (56009 'Choose the attachment type.' / 'The attachment type {name} is not used for
-- items.'). THE PICTURE (@IsItemImage 1) IS UNCHANGED: no type check, it replaces the item's picture, and it keeps no
-- type, date or note.
CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_Add
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

-- New (67): an item's documents (one with @FileId), newest first, in the shape of every family's *File_List
-- (DocumentId = the item); IsOther = still typed "Other". Never the item's picture.
CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_List
    @ItemId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.ItemId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM inventory.ItemFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ItemId = @ItemId AND f.IsItemImage = 0
      AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

-- Re-created (67) from the body of script 49: one edit as script 55 made it for every family - the type, date and
-- note (a type is required, active and used for items, except that a file may keep the type it has though it was
-- deactivated since), @FileName (NULL or blank keeps it) and optionally a new version of the file (NULL keeps the
-- stored one). Answers the file's row (usp_ItemFile_List's). The picture: its name and file only, as before (no row
-- answered: the list never shows it). @UserId is taken for the callers' shape; an item keeps no audit of its files.
CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_Update
    @Id          INT,
    @FileName    NVARCHAR(255)  = NULL,   -- (67) NULL / blank keeps the name
    @ContentType NVARCHAR(100)  = NULL,   -- with @Content: a new version of the file
    @SizeBytes   INT            = NULL,
    @Content     VARBINARY(MAX) = NULL,
    @AttachmentTypeId INT           = NULL,   -- (67)
    @DocumentDate     DATE          = NULL,   -- (67)
    @Note             NVARCHAR(500) = NULL,   -- (67)
    @UserId           INT           = NULL    -- (67)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ItemId INT, @Old NVARCHAR(255), @OldType INT, @IsImage BIT;
    SELECT @ItemId = ItemId, @Old = FileName, @OldType = AttachmentTypeId, @IsImage = IsItemImage
    FROM inventory.ItemFiles WHERE Id = @Id;
    IF @ItemId IS NULL THROW 56006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    -- the type the file has may stay though deactivated since; a new choice is checked as the upload's
    IF @IsImage = 0 AND (@AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1))
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'ITEM', 56009;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 56000, 'The file is empty.', 1;

    UPDATE inventory.ItemFiles
    SET FileName         = @FileName,
        ContentType      = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
        SizeBytes        = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
        Content          = ISNULL(@Content, Content),
        AttachmentTypeId = CASE WHEN IsItemImage = 1 THEN NULL ELSE @AttachmentTypeId END,
        DocumentDate     = CASE WHEN IsItemImage = 1 THEN NULL ELSE @DocumentDate END,
        Note             = CASE WHEN IsItemImage = 1 THEN NULL ELSE NULLIF(LTRIM(RTRIM(@Note)), N'') END
    WHERE Id = @Id;

    EXEC inventory.usp_ItemFile_List @ItemId = @ItemId, @FileId = @Id;
END
GO

/* ================================================================== 5. Attachment types: + the item files in "used" */

-- Re-created (67) from the body of script 64: + the item files.
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
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptFiles WHERE AttachmentTypeId = @Id)   -- (64)
       OR EXISTS (SELECT 1 FROM inventory.StockDocumentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM inventory.ItemFiles WHERE AttachmentTypeId = @Id)          -- (67)
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

/* ================================================================== 6. Container documents: re-link to a movement */

/* Re-created (67) from the body of script 55: + @MovementId / @SetMovement. One upload may be shared by several
   containers (attached to them together). @AllShared = 1 edits the upload and the type / date / note of every one of
   them, like deleting it everywhere; 0 edits this container's record only - and a new name or file then becomes this
   container's own copy, leaving the others on the upload as it was. (67) @SetMovement = 1 files the records edited
   (this one, or every one of the upload with @AllShared = 1) under @MovementId - NULL = General, not tied to a
   movement -, with the upload's check: every container of those records must be on that movement (70000). 0 (the
   default) leaves the link as it is. The charge link never changes here. Answers the record. */
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
    @UserId           INT            = NULL,
    @MovementId       INT            = NULL,   -- (67) with @SetMovement = 1: the movement, NULL = General
    @SetMovement      BIT            = 0       -- (67) 1 = change the movement link
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @AllShared = ISNULL(@AllShared, 0);
    SET @SetMovement = ISNULL(@SetMovement, 0);

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

    -- (67) the movement link: the upload's checks and message (usp_ContainerAttachment_Add)
    DECLARE @Msg NVARCHAR(400), @Moved BIT = 0, @MovementText NVARCHAR(60) = NULL;
    IF @SetMovement = 1
    BEGIN
        IF @MovementId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId) THROW 70006, 'Movement not found.', 1;
            SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not part of this movement.'
            FROM @Rows r INNER JOIN logistics.Containers c ON c.Id = r.ContainerId
            WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = r.ContainerId)
            ORDER BY c.ContainerRef;
            IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
        END
        IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments a INNER JOIN @Rows r ON r.Id = a.Id
                   WHERE ISNULL(a.MovementId, -1) <> ISNULL(@MovementId, -1))
        BEGIN
            SET @Moved = 1;
            SET @MovementText = ISNULL(N' (movement ' + (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId) + N')', N' (General)');
        END
    END

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

        UPDATE a SET AttachmentTypeId = @AttachmentTypeId, Note = @Note, DocumentDate = @DocumentDate,
                     MovementId = CASE WHEN @SetMovement = 1 THEN @MovementId ELSE a.MovementId END   -- (67)
        FROM logistics.ContainerAttachments a INNER JOIN @Rows r ON r.Id = a.Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT DISTINCT r.ContainerId, N'Updated',
               LEFT(N'Attachment edited: ' + CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                    + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END
                    + CASE WHEN @Moved = 1 THEN @MovementText ELSE N'' END, 500), @UserId   -- (67)
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

/* ================================================================== 7. Container charges: their files say "Other" */

-- Re-created (67) from the body of script 47: + IsOther on the charge's files (the container list's expression: no
-- type, or Other / Other, General / Other).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           ch.MovementId, m.MovementNo, ch.GroupId,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload, ch.Notes,
           ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, xu.FullName AS CancelledByName, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.UpdatedAtUtc, uu.FullName AS UpdatedByName, ch.RowVersion,
           -- (47) supplier payments: posted charges only (NULL otherwise)
           PaidAmount = pst.PaidAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus
    FROM logistics.ContainerCharges ch
    OUTER APPLY logistics.fn_ContainerChargeSettlement(ch.Id) pst
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = ch.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = ch.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = ch.UpdatedBy
    WHERE ch.Id = @Id;

    SELECT cl.Id AS ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           QuantityBase = ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase),
           a.Basis, AmountBase = ISNULL(a.AmountBase, 0), IsManual = ISNULL(a.IsManual, 0),
           PerUnitBase = ISNULL(a.AmountBase, 0) / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.ContainerLines cl ON cl.ContainerId = ch.ContainerId
    INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
    LEFT  JOIN logistics.ContainerChargeAllocations a ON a.ChargeId = ch.Id AND a.ContainerLineId = cl.Id
    WHERE ch.Id = @Id
    ORDER BY cl.LineNumber;

    SELECT a.Id, a.ContainerId, a.MovementId, a.AttachmentTypeId, at.Category, at.SubType,
           IsOther = CAST(CASE WHEN at.Id IS NULL OR (at.SubType = N'Other' AND at.Category IN (N'Other', N'General')) THEN 1 ELSE 0 END AS BIT),   -- (67)
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u ON u.Id = a.CreatedBy
    WHERE a.ChargeId = @Id
    ORDER BY a.CreatedAtUtc DESC;

    SELECT g.Id, g.ContainerId, c.ContainerRef, c.ContainerNo, g.Amount, g.AmountBase, g.Status, g.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.ContainerCharges g ON g.GroupId = ch.GroupId AND g.Id <> ch.Id
    INNER JOIN logistics.Containers c       ON c.Id = g.ContainerId
    WHERE ch.Id = @Id AND ch.GroupId IS NOT NULL
    ORDER BY c.ContainerRef;
END
GO

/* ================================================================== 99. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'masterdata.fn_AttachmentDocumentKinds'), (N'inventory.usp_ItemFile_Add'), (N'inventory.usp_ItemFile_List'),
             (N'inventory.usp_ItemFile_Update'), (N'masterdata.usp_AttachmentType_Delete'),
             (N'logistics.usp_ContainerAttachment_Update'), (N'logistics.usp_ContainerCharge_Get'),
             (N'FK_ItemFiles_Type'), (N'CK_ItemFiles_Type')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = ISNULL(OBJECT_ID(o.ObjectName),
                                                  (SELECT TOP (1) x.object_id FROM sys.objects x
                                                   WHERE x.name = o.ObjectName AND x.parent_object_id = OBJECT_ID(N'inventory.ItemFiles')))
ORDER BY ObjectType, o.ObjectName;   -- expected 9: 1 function, 5 procedures, the foreign key and the check, none MISSING

-- The types used for items (as an administrator left them).
SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.IsActive
FROM masterdata.AttachmentTypes a
WHERE EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = N'ITEM')
ORDER BY a.SortOrder, a.Category, a.SubType;

-- The files still typed "Other" in each family: the pages ask "Choose a type" on each of them.
SELECT x.Family, Files = COUNT(x.FileId),
       TypedOther = ISNULL(SUM(CASE WHEN x.FileId IS NOT NULL
                                     AND (t.Id IS NULL OR (t.SubType = N'Other' AND t.Category IN (N'Other', N'General'))) THEN 1 ELSE 0 END), 0)
FROM (SELECT N'1 Purchase documents', Id, AttachmentTypeId FROM purchase.PurchaseDocumentFiles
      UNION ALL SELECT N'2 Goods receipts', Id, AttachmentTypeId FROM purchase.GoodsReceiptFiles
      UNION ALL SELECT N'3 Supplier payments', Id, AttachmentTypeId FROM purchase.PaymentFiles
      UNION ALL SELECT N'4 Sales documents', Id, AttachmentTypeId FROM sales.SalesDocumentFiles
      UNION ALL SELECT N'5 Customer receipts', Id, AttachmentTypeId FROM sales.ReceiptFiles
      UNION ALL SELECT N'6 Stock documents', Id, AttachmentTypeId FROM inventory.StockDocumentFiles
      UNION ALL SELECT N'7 Containers', Id, AttachmentTypeId FROM logistics.ContainerAttachments
      UNION ALL SELECT N'8 Items', Id, AttachmentTypeId FROM inventory.ItemFiles WHERE IsItemImage = 0
      UNION ALL SELECT f.Family, NULL, NULL
      FROM (VALUES (N'1 Purchase documents'), (N'2 Goods receipts'), (N'3 Supplier payments'), (N'4 Sales documents'),
                   (N'5 Customer receipts'), (N'6 Stock documents'), (N'7 Containers'), (N'8 Items')) f (Family)) x (Family, FileId, AttachmentTypeId)
LEFT JOIN masterdata.AttachmentTypes t ON t.Id = x.AttachmentTypeId
GROUP BY x.Family
ORDER BY x.Family;

-- A kind no active type is used for cannot take a file: expected no row.
SELECT KindWithoutActiveType = k.Code, k.Name
FROM masterdata.fn_AttachmentDocumentKinds() k
WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u
                  INNER JOIN masterdata.AttachmentTypes t ON t.Id = u.AttachmentTypeId AND t.IsActive = 1
                  WHERE u.DocumentKind = k.Code)
ORDER BY k.SortOrder;

PRINT 'Script 67 applied: item documents (kind ITEM: type, date, note; old files "Other"; the picture unchanged), '
      + 'container files re-linked to a movement, charge files flag "Other".';
GO

SET NOEXEC OFF;
GO
