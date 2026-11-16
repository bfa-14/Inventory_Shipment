SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 101: REPORTING - THE ATTACHMENT REPORT

   Reports › Attachment Report: every attachment of every document, filtered by attachment type and by two date ranges
   (the document date typed on the file, and the day it was uploaded), listed a page at a time, downloaded one by one,
   selected, or all at once in a ZIP.

     1. THE PERMISSION reports.attachments.view "View Attachment Report" (module Reports, 1500). Not granted to any role
        here: the start-up sync gives every permission to the system roles, and the others get it in Role Permissions.
     2. reporting.AttachmentDownloads: one row per download (who, when, which filters or files, how many, how big).
     3. reporting.fn_Attachments(): ONE LIST OVER THE TEN PLACES FILES ARE KEPT - a container's documents
        (logistics.ContainerAttachments + logistics.Files: one row per container a file is filed under), purchase
        orders / invoices / returns, goods receipts, supplier payments, sales invoices / returns / orders, receipts,
        Inventory In / Out / BIVAC Out, transfer orders, and item documents (the item's picture is not a document and
        is left out). The old logistics.ContainerFiles is not read: nothing has written it since script 55.
          Source + Id     the key of the file row (CNT = the container's attachment row; PDOC, GRN, PAY, SDOC, RCPT,
                          STK, TRO, ITEM = the module's file table)
          DocumentKind    the document type code (PO, PINV, PRET, GRN, PAY, SINV, SRET, SO, RCPT, INV_IN, INV_OUT,
                          BIV_OUT, TRO, TRD, TRR, CONTAINER, ITEM): what the API checks the reader's permissions on
          Reference       the container ref, the document number (a draft without one: "PINV draft #12"), the item code
     4. reporting.usp_AttachmentReport_List: one page of that list, newest first, and the total count and size of
        everything that matches. Only the kinds the API passes in @Kinds (the reader's) are ever read.
     5. reporting.usp_AttachmentReport_Files: the files a download takes - the chosen keys, or everything that matches
        the filters - without their content, so the API can check the limits and name the files first.
     6. reporting.usp_AttachmentReport_Content: the content of the chosen keys, streamed by the API into the ZIP.
     7. reporting.usp_AttachmentReport_LogDownload.
     8. Indexes on each file table by document date and upload date, covering everything the list reads but the
        content, so the list never touches the files themselves.

   Filters: types, document date and upload date combine with AND; an empty type list is every type; a document-date
   range leaves out the files that have no document date. Dates are inclusive. No new error number.

   Requires scripts 49, 52, 67 and 90 (the attachment types and the file tables). Idempotent, additive.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'masterdata.AttachmentTypes', N'U') IS NULL
   OR OBJECT_ID(N'logistics.ContainerAttachments', N'U') IS NULL
   OR OBJECT_ID(N'inventory.ItemFiles', N'U') IS NULL
   OR OBJECT_ID(N'inventory.TransferOrderFiles', N'U') IS NULL
    THROW 50000, 'Script 101 requires scripts 49, 52, 67 and 90: apply them first.', 1;
GO

IF SCHEMA_ID(N'reporting') IS NULL EXEC (N'CREATE SCHEMA reporting');
GO

/* ================================================================== 1. reports.attachments.view */

-- The texts are PermissionCatalog.cs's, so the start-up sync changes nothing.
MERGE security.Permissions AS target
USING (VALUES (N'reports.attachments.view', N'View Attachment Report', N'Reports',
               N'Reports › Attachment Report: find attachments by type and date and download them; each reader sees only the files of documents they may open.',
               1500)) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                  OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

/* ================================================================== 2. The download log */

IF OBJECT_ID(N'reporting.AttachmentDownloads', N'U') IS NULL
    CREATE TABLE reporting.AttachmentDownloads
    (
        Id               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AttachmentDownloads PRIMARY KEY,
        UserId           INT            NOT NULL,
        DownloadedAtUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_AttachmentDownloads_At DEFAULT SYSUTCDATETIME(),
        Mode             NVARCHAR(20)   NOT NULL,   -- Selected | All
        FileCount        INT            NOT NULL,
        TotalBytes       BIGINT         NOT NULL,
        Criteria         NVARCHAR(MAX)  NULL,       -- the filters (All) or the keys (Selected), as JSON
        CONSTRAINT CK_AttachmentDownloads_Mode CHECK (Mode IN (N'Selected', N'All'))
    );
GO

/* ================================================================== 3. Indexes: the list reads these, never the content */

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ContainerAttachments_Report' AND object_id = OBJECT_ID(N'logistics.ContainerAttachments'))
    CREATE INDEX IX_ContainerAttachments_Report ON logistics.ContainerAttachments (DocumentDate, CreatedAtUtc)
        INCLUDE (ContainerId, FileId, AttachmentTypeId, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PurchaseDocumentFiles_Report' AND object_id = OBJECT_ID(N'purchase.PurchaseDocumentFiles'))
    CREATE INDEX IX_PurchaseDocumentFiles_Report ON purchase.PurchaseDocumentFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (DocumentId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_GoodsReceiptFiles_Report' AND object_id = OBJECT_ID(N'purchase.GoodsReceiptFiles'))
    CREATE INDEX IX_GoodsReceiptFiles_Report ON purchase.GoodsReceiptFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (GoodsReceiptId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PaymentFiles_Report' AND object_id = OBJECT_ID(N'purchase.PaymentFiles'))
    CREATE INDEX IX_PaymentFiles_Report ON purchase.PaymentFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (PaymentId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SalesDocumentFiles_Report' AND object_id = OBJECT_ID(N'sales.SalesDocumentFiles'))
    CREATE INDEX IX_SalesDocumentFiles_Report ON sales.SalesDocumentFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (DocumentId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ReceiptFiles_Report' AND object_id = OBJECT_ID(N'sales.ReceiptFiles'))
    CREATE INDEX IX_ReceiptFiles_Report ON sales.ReceiptFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (ReceiptId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_StockDocumentFiles_Report' AND object_id = OBJECT_ID(N'inventory.StockDocumentFiles'))
    CREATE INDEX IX_StockDocumentFiles_Report ON inventory.StockDocumentFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (DocumentId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TransferOrderFiles_Report' AND object_id = OBJECT_ID(N'inventory.TransferOrderFiles'))
    CREATE INDEX IX_TransferOrderFiles_Report ON inventory.TransferOrderFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (TransferOrderId, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ItemFiles_Report' AND object_id = OBJECT_ID(N'inventory.ItemFiles'))
    CREATE INDEX IX_ItemFiles_Report ON inventory.ItemFiles (DocumentDate, CreatedAtUtc)
        INCLUDE (ItemId, IsItemImage, AttachmentTypeId, FileName, ContentType, SizeBytes, CreatedBy);
GO

/* ================================================================== 4. reporting.fn_Attachments */

CREATE OR ALTER FUNCTION reporting.fn_Attachments ()
RETURNS TABLE
AS
RETURN
(
    -- A container's documents: one row per container the file is filed under (one upload may serve several).
    SELECT Source = CAST(N'CNT' AS NVARCHAR(4)), a.Id, DocumentKind = CAST(N'CONTAINER' AS NVARCHAR(12)),
           OwnerId = a.ContainerId, Reference = CAST(c.ContainerRef AS NVARCHAR(60)), a.AttachmentTypeId,
           f.FileName, f.ContentType, f.SizeBytes, a.DocumentDate, UploadedAtUtc = a.CreatedAtUtc, UploadedBy = a.CreatedBy
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f      ON f.Id = a.FileId
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId

    UNION ALL
    SELECT N'PDOC', x.Id, dt.Code, x.DocumentId,
           ISNULL(d.DocumentNumber, dt.Code + N' draft #' + CAST(d.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM purchase.PurchaseDocumentFiles x
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = x.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId

    UNION ALL
    SELECT N'GRN', x.Id, N'GRN', x.GoodsReceiptId,
           ISNULL(g.DocumentNumber, N'GRN draft #' + CAST(g.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM purchase.GoodsReceiptFiles x
    INNER JOIN purchase.GoodsReceipts g ON g.Id = x.GoodsReceiptId

    UNION ALL
    SELECT N'PAY', x.Id, N'PAY', x.PaymentId,
           ISNULL(p.PaymentNumber, N'PAY draft #' + CAST(p.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM purchase.PaymentFiles x
    INNER JOIN purchase.Payments p ON p.Id = x.PaymentId

    UNION ALL
    SELECT N'SDOC', x.Id, dt.Code, x.DocumentId,
           ISNULL(d.DocumentNumber, dt.Code + N' draft #' + CAST(d.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM sales.SalesDocumentFiles x
    INNER JOIN sales.SalesDocuments d     ON d.Id = x.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId

    UNION ALL
    SELECT N'RCPT', x.Id, N'RCPT', x.ReceiptId,
           ISNULL(r.ReceiptNumber, N'RCPT draft #' + CAST(r.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM sales.ReceiptFiles x
    INNER JOIN sales.Receipts r ON r.Id = x.ReceiptId

    UNION ALL
    SELECT N'STK', x.Id, dt.Code, x.DocumentId,
           ISNULL(d.DocumentNumber, dt.Code + N' draft #' + CAST(d.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM inventory.StockDocumentFiles x
    INNER JOIN inventory.StockDocuments d ON d.Id = x.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId

    UNION ALL
    SELECT N'TRO', x.Id, dt.Code, x.TransferOrderId,
           ISNULL(t.DocumentNumber, dt.Code + N' draft #' + CAST(t.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM inventory.TransferOrderFiles x
    INNER JOIN inventory.TransferOrders t ON t.Id = x.TransferOrderId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = t.DocumentTypeId

    UNION ALL
    -- The item's picture is not one of its documents.
    SELECT N'ITEM', x.Id, N'ITEM', x.ItemId, CAST(i.ItemCode AS NVARCHAR(60)), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM inventory.ItemFiles x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.IsItemImage = 0
);
GO

/* ================================================================== 5. reporting.usp_AttachmentReport_List */

CREATE OR ALTER PROCEDURE reporting.usp_AttachmentReport_List
    @Kinds       NVARCHAR(400),            -- the document kinds the reader may open, comma separated (the API's)
    @TypeIds     NVARCHAR(MAX) = NULL,     -- attachment type ids, comma separated; empty = every type
    @DocFrom     DATE = NULL,
    @DocTo       DATE = NULL,
    @UploadFrom  DATE = NULL,
    @UploadTo    DATE = NULL,
    @Page        INT = 1,
    @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;

    DECLARE @K TABLE (Kind NVARCHAR(12) NOT NULL PRIMARY KEY);
    INSERT INTO @K (Kind) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@Kinds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'';
    DECLARE @T TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @T (Id) SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@TypeIds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'' AND TRY_CAST(value AS INT) IS NOT NULL;
    DECLARE @AnyType BIT = CASE WHEN EXISTS (SELECT 1 FROM @T) THEN 0 ELSE 1 END;
    -- Upload dates are UTC timestamps: a day runs to the next midnight.
    DECLARE @UploadToNext DATETIME2(3) = CASE WHEN @UploadTo IS NULL THEN NULL ELSE DATEADD(DAY, 1, CAST(@UploadTo AS DATETIME2(3))) END;

    SELECT a.Source, a.Id, a.DocumentKind, a.OwnerId, a.Reference, a.AttachmentTypeId,
           at.Category AS TypeCategory, at.SubType AS TypeSubType,
           a.FileName, a.ContentType, a.SizeBytes, a.DocumentDate, a.UploadedAtUtc, u.FullName AS UploadedByName
    INTO #M
    FROM reporting.fn_Attachments() a
    INNER JOIN @K k ON k.Kind = a.DocumentKind
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u ON u.Id = a.UploadedBy
    WHERE (@AnyType = 1 OR a.AttachmentTypeId IN (SELECT Id FROM @T))
      AND (@DocFrom IS NULL OR a.DocumentDate >= @DocFrom)
      AND (@DocTo IS NULL OR a.DocumentDate <= @DocTo)
      AND (@UploadFrom IS NULL OR a.UploadedAtUtc >= CAST(@UploadFrom AS DATETIME2(3)))
      AND (@UploadToNext IS NULL OR a.UploadedAtUtc < @UploadToNext);

    -- Newest first: by the document's own date, else the day it was uploaded.
    -- The document date goes out as plain yyyy-MM-dd text: a calendar date, never a timestamp.
    SELECT m.Source, m.Id, m.DocumentKind, m.OwnerId, m.Reference, m.AttachmentTypeId, m.TypeCategory, m.TypeSubType,
           m.FileName, m.ContentType, m.SizeBytes, DocumentDate = CONVERT(CHAR(10), m.DocumentDate, 23), m.UploadedAtUtc,
           m.UploadedByName
    FROM #M m
    ORDER BY ISNULL(m.DocumentDate, CAST(m.UploadedAtUtc AS DATE)) DESC, m.UploadedAtUtc DESC, m.Source, m.Id
    OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    SELECT TotalCount = COUNT(*), TotalBytes = ISNULL(SUM(CAST(SizeBytes AS BIGINT)), 0) FROM #M;
END
GO

/* ================================================================== 6. reporting.usp_AttachmentReport_Files */

CREATE OR ALTER PROCEDURE reporting.usp_AttachmentReport_Files
    @Kinds       NVARCHAR(400),
    @Keys        NVARCHAR(MAX) = NULL,     -- "CNT:12,PDOC:3": the chosen files; NULL = everything matching the filters
    @TypeIds     NVARCHAR(MAX) = NULL,
    @DocFrom     DATE = NULL,
    @DocTo       DATE = NULL,
    @UploadFrom  DATE = NULL,
    @UploadTo    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @K TABLE (Kind NVARCHAR(12) NOT NULL PRIMARY KEY);
    INSERT INTO @K (Kind) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@Kinds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'';
    DECLARE @T TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @T (Id) SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@TypeIds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'' AND TRY_CAST(value AS INT) IS NOT NULL;
    DECLARE @AnyType BIT = CASE WHEN EXISTS (SELECT 1 FROM @T) THEN 0 ELSE 1 END;
    DECLARE @UploadToNext DATETIME2(3) = CASE WHEN @UploadTo IS NULL THEN NULL ELSE DATEADD(DAY, 1, CAST(@UploadTo AS DATETIME2(3))) END;

    DECLARE @Chosen TABLE (Source NVARCHAR(4) NOT NULL, Id INT NOT NULL, PRIMARY KEY (Source, Id));
    IF @Keys IS NOT NULL
        INSERT INTO @Chosen (Source, Id)
        SELECT DISTINCT LEFT(k.v, CHARINDEX(N':', k.v) - 1), TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT)
        FROM (SELECT v = LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Keys, N',')) k
        WHERE CHARINDEX(N':', k.v) > 1 AND TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT) IS NOT NULL;

    -- A key of a kind the reader may not open is simply not found: the same rule as the list.
    SELECT a.Source, a.Id, a.DocumentKind, a.Reference, a.AttachmentTypeId,
           at.Category AS TypeCategory, at.SubType AS TypeSubType,
           a.FileName, a.ContentType, a.SizeBytes, DocumentDate = CONVERT(CHAR(10), a.DocumentDate, 23), a.UploadedAtUtc
    FROM reporting.fn_Attachments() a
    INNER JOIN @K k ON k.Kind = a.DocumentKind
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    WHERE (@Keys IS NOT NULL AND EXISTS (SELECT 1 FROM @Chosen c WHERE c.Source = a.Source AND c.Id = a.Id))
       OR (@Keys IS NULL
           AND (@AnyType = 1 OR a.AttachmentTypeId IN (SELECT Id FROM @T))
           AND (@DocFrom IS NULL OR a.DocumentDate >= @DocFrom)
           AND (@DocTo IS NULL OR a.DocumentDate <= @DocTo)
           AND (@UploadFrom IS NULL OR a.UploadedAtUtc >= CAST(@UploadFrom AS DATETIME2(3)))
           AND (@UploadToNext IS NULL OR a.UploadedAtUtc < @UploadToNext))
    ORDER BY a.Reference, ISNULL(a.DocumentDate, CAST(a.UploadedAtUtc AS DATE)), a.Source, a.Id;
END
GO

/* ================================================================== 7. reporting.usp_AttachmentReport_Content */

-- The bytes of the chosen files, one row each: Source, Id, Content. The API asks only for keys usp_AttachmentReport_Files
-- has just answered for the reader, and reads the content as a stream (one file at a time, never the whole set at once).
CREATE OR ALTER PROCEDURE reporting.usp_AttachmentReport_Content
    @Keys NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Chosen TABLE (Source NVARCHAR(4) NOT NULL, Id INT NOT NULL, PRIMARY KEY (Source, Id));
    INSERT INTO @Chosen (Source, Id)
    SELECT DISTINCT LEFT(k.v, CHARINDEX(N':', k.v) - 1), TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT)
    FROM (SELECT v = LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@Keys, N''), N',')) k
    WHERE CHARINDEX(N':', k.v) > 1 AND TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT) IS NOT NULL;

    SELECT c.Source, c.Id, Content = COALESCE(cf.Content, pd.Content, gr.Content, py.Content, sd.Content, rc.Content,
                                              st.Content, tr.Content, it.Content)
    FROM @Chosen c
    LEFT JOIN logistics.ContainerAttachments ca ON c.Source = N'CNT'  AND ca.Id = c.Id
    LEFT JOIN logistics.Files cf                ON cf.Id = ca.FileId
    LEFT JOIN purchase.PurchaseDocumentFiles pd ON c.Source = N'PDOC' AND pd.Id = c.Id
    LEFT JOIN purchase.GoodsReceiptFiles gr     ON c.Source = N'GRN'  AND gr.Id = c.Id
    LEFT JOIN purchase.PaymentFiles py          ON c.Source = N'PAY'  AND py.Id = c.Id
    LEFT JOIN sales.SalesDocumentFiles sd       ON c.Source = N'SDOC' AND sd.Id = c.Id
    LEFT JOIN sales.ReceiptFiles rc             ON c.Source = N'RCPT' AND rc.Id = c.Id
    LEFT JOIN inventory.StockDocumentFiles st   ON c.Source = N'STK'  AND st.Id = c.Id
    LEFT JOIN inventory.TransferOrderFiles tr   ON c.Source = N'TRO'  AND tr.Id = c.Id
    LEFT JOIN inventory.ItemFiles it            ON c.Source = N'ITEM' AND it.Id = c.Id AND it.IsItemImage = 0
    ORDER BY c.Source, c.Id;
END
GO

/* ================================================================== 8. reporting.usp_AttachmentReport_LogDownload */

CREATE OR ALTER PROCEDURE reporting.usp_AttachmentReport_LogDownload
    @UserId     INT,
    @Mode       NVARCHAR(20),
    @FileCount  INT,
    @TotalBytes BIGINT,
    @Criteria   NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO reporting.AttachmentDownloads (UserId, Mode, FileCount, TotalBytes, Criteria)
    VALUES (@UserId, @Mode, @FileCount, @TotalBytes, @Criteria);
END
GO

/* ================================================================== 9. Check */

SELECT a.DocumentKind, Files = COUNT(*), TotalBytes = SUM(CAST(a.SizeBytes AS BIGINT))
FROM reporting.fn_Attachments() a
GROUP BY a.DocumentKind
ORDER BY a.DocumentKind;

PRINT 'Script 101 applied: the Attachment Report (reports.attachments.view, reporting.fn_Attachments, usp_AttachmentReport_*).';
GO
