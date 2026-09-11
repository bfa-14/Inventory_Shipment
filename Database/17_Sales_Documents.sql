/* =====================================================================================
   Inventory_Shipment - 17: SALES document family (Sales Invoice first; Sales Order / Return later)

   One header table + one lines table for the whole Sales family, discriminated by the document type
   (inventory.DocumentTypes: SO = Sales Order (no stock effect), SINV = Sales Invoice (stock -1),
   SRET = Sales Return (stock +1)). Only SINV is exposed by the API / page now; the procedures are
   already generic (they read StockDirection from the configuration table).

   Objects (schema sales):
     SalesDocuments / SalesDocumentLines / SalesDocumentFiles / SalesDocumentAudit
     tvp_SalesDocumentLine
     usp_SalesDocument_Search / _Get / _ValidateInput / _Save / _Post / _Cancel / _Delete
     usp_SalesDocumentFile_Add / _Get / _Delete
     usp_SalesDocument_ResolveRate       - exchange rate the page shows before saving
     InvoiceImportLogs                   - InvoiceId is now a real FK to SalesDocuments; PriceListId nullable
                                           (stock-mode imports); usp_InvoiceImport_Log RE-CREATED (same
                                           signature, @PriceListId NULL allowed, audit row on the invoice)

   Business rules
     - Client = a party flagged Client (active); Salesman = a party flagged Salesman (optional).
     - Price List is required; the invoice CURRENCY is the price list currency (snapshot on the header).
     - Exchange rate: 1 base currency = Rate x invoice currency, taken from masterdata.fn_GetRate for the
       chosen RateType (1 Official default, 2 NonOfficial, 3 Market) at the document date; the user may
       override it (@ExchangeRate); base currency -> 1. Amounts are stored in the invoice currency and the
       base-currency equivalent (Amount / Rate) is stored beside them for reporting.
     - Line prices: when the caller has NO price-override permission (@AllowPriceOverride = 0) the line
       price is ALWAYS the price list price (fn_GetUnitPrice: branch price -> all-branches price); a line
       without any price list price is refused (64011 NO_PRICE). With the permission, a manual price is kept
       (PriceSource = Manual when it differs from the price list price).
     - Discount % per line between 0 and @MaxDiscountPercent (configuration Sales:MaxDiscountPercent).
     - Lines store Quantity in the chosen unit + PackingFormula snapshot; LineTotal = Qty x Price x (1 - Disc%).
     - Lifecycle: Draft (editable) -> Posted (SINV: stock movements written, COGS snapshot per line from the
       average cost, number INV-000001 assigned) -> Cancelled (reversal movements). Drafts can be deleted.
     - Posting an invoice needs enough stock per item + warehouse (64007 INSUFFICIENT_STOCK).
     - Excel import: the wizard logs every import (sales.InvoiceImportLogs); Save links the logs written
       under @DraftReference to the invoice (usp_InvoiceImport_AttachInvoice).

   Error numbers (read by the API):
     64000 validation ("Line N: ..." for line problems)   64004 concurrency   64005 not a draft
     64006 not found   64007 insufficient stock   64008 master data missing / inactive / no exchange rate
     64009 no lines   64010 invalid status transition   64011 no selling price for a line
   Permissions (module Sales): sales.invoices.view / create / post / cancel / delete (620-660).
     (sales.invoices.import 600 and sales.invoices.priceoverride 610 already exist - script 14.)

   Requires 06, 07, 08, 11, 12, 13, 14, 15. Idempotent. Table types cannot be altered - drop the procs first.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.DocumentTypes', N'U') IS NULL OR OBJECT_ID(N'inventory.StockMovements', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Parties', N'U') IS NULL OR OBJECT_ID(N'masterdata.PriceLists', N'U') IS NULL
   OR OBJECT_ID(N'sales.InvoiceImportLogs', N'U') IS NULL OR OBJECT_ID(N'masterdata.fn_GetRate', N'FN') IS NULL
BEGIN
    RAISERROR ('Run scripts 08, 12, 13, 14 and 15 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'sales.SalesDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocuments
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId   INT            NOT NULL,     -- SO | SINV | SRET (inventory.DocumentTypes, Family = Sales)
        DocumentNumber   NVARCHAR(30)   NULL,         -- NULL while a draft of a NumberOnPost type (SINV)
        DocumentDate     DATE           NOT NULL,
        DueDate          DATE           NULL,
        BranchId         INT            NOT NULL,
        WarehouseId      INT            NOT NULL,     -- default warehouse (lines may differ)
        ClientId         INT            NOT NULL,     -- masterdata.Parties (IsClient)   - name matters: party type guard
        SalesmanId       INT            NULL,         -- masterdata.Parties (IsSalesman) - name matters: party type guard
        PriceListId      INT            NOT NULL,
        CurrencyId       INT            NOT NULL,     -- = price list currency (snapshot)
        RateType         TINYINT        NOT NULL CONSTRAINT DF_SalesDocuments_RateType DEFAULT (1),   -- 1 Official, 2 NonOfficial, 3 Market
        ExchangeRate     DECIMAL(18,6)  NOT NULL CONSTRAINT DF_SalesDocuments_Rate DEFAULT (1),       -- 1 base = Rate x currency
        ReferenceNo      NVARCHAR(100)  NULL,         -- client order / external reference
        Notes            NVARCHAR(1000) NULL,
        Status           TINYINT        NOT NULL CONSTRAINT DF_SalesDocuments_Status DEFAULT (1),     -- 1 Draft, 2 Posted, 3 Cancelled
        TotalItems       INT            NOT NULL CONSTRAINT DF_SalesDocuments_TotalItems DEFAULT (0),
        TotalQuantity    INT            NOT NULL CONSTRAINT DF_SalesDocuments_TotalQuantity DEFAULT (0),   -- base units
        Subtotal         DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_Subtotal DEFAULT (0),       -- before discounts, invoice currency
        TotalDiscount    DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalDiscount DEFAULT (0),
        TotalAmount      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalAmount DEFAULT (0),    -- invoice currency
        TotalAmountBase  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalAmountBase DEFAULT (0),-- base currency (= TotalAmount / ExchangeRate)
        TotalCostBase    DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalCostBase DEFAULT (0),  -- COGS at posting, base currency
        SourceDocumentId INT            NULL,         -- family pattern: SO -> SINV / SINV -> SRET conversions (later)
        PostedAtUtc      DATETIME2(3)   NULL,
        PostedBy         INT            NULL,
        CancelledAtUtc   DATETIME2(3)   NULL,
        CancelledBy      INT            NULL,
        CancelReason     NVARCHAR(300)  NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_SalesDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        UpdatedAtUtc     DATETIME2(3)   NULL,
        UpdatedBy        INT            NULL,
        RowVersion       ROWVERSION     NOT NULL,
        CONSTRAINT PK_SalesDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_SalesDocuments_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT CK_SalesDocuments_RateType CHECK (RateType IN (1, 2, 3)),
        CONSTRAINT CK_SalesDocuments_Rate CHECK (ExchangeRate > 0),
        CONSTRAINT CK_SalesDocuments_DueDate CHECK (DueDate IS NULL OR DueDate >= DocumentDate),
        CONSTRAINT FK_SalesDocuments_Type        FOREIGN KEY (DocumentTypeId)   REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_SalesDocuments_Branch      FOREIGN KEY (BranchId)         REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_SalesDocuments_Warehouse   FOREIGN KEY (WarehouseId)      REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_SalesDocuments_Client      FOREIGN KEY (ClientId)         REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_SalesDocuments_Salesman    FOREIGN KEY (SalesmanId)       REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_SalesDocuments_PriceList   FOREIGN KEY (PriceListId)      REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_SalesDocuments_Currency    FOREIGN KEY (CurrencyId)       REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_SalesDocuments_Source      FOREIGN KEY (SourceDocumentId) REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_SalesDocuments_CreatedBy   FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_SalesDocuments_UpdatedBy   FOREIGN KEY (UpdatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_SalesDocuments_PostedBy    FOREIGN KEY (PostedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_SalesDocuments_CancelledBy FOREIGN KEY (CancelledBy)      REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_SalesDocuments_Number ON sales.SalesDocuments (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_TypeDate   ON sales.SalesDocuments (DocumentTypeId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_TypeStatus ON sales.SalesDocuments (DocumentTypeId, Status);
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_Client     ON sales.SalesDocuments (ClientId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_Salesman   ON sales.SalesDocuments (SalesmanId) WHERE SalesmanId IS NOT NULL;
    PRINT 'Created sales.SalesDocuments';
END
GO

IF OBJECT_ID(N'sales.SalesDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocumentLines
    (
        Id              INT IDENTITY(1,1) NOT NULL,
        DocumentId      INT           NOT NULL,
        LineNumber      INT           NOT NULL,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        WarehouseId     INT           NOT NULL,
        ExpiryDate      DATE          NULL,
        Quantity        INT           NOT NULL,          -- in the chosen unit
        PackingFormula  INT           NOT NULL,          -- snapshot from the item unit at save time
        QuantityBase    AS (Quantity * PackingFormula) PERSISTED,
        UnitPrice       DECIMAL(18,4) NOT NULL,          -- per unit, invoice currency
        DiscountPercent DECIMAL(9,4)  NOT NULL CONSTRAINT DF_SalesDocumentLines_Discount DEFAULT (0),
        LineDiscount    AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * DiscountPercent / 100.0)) PERSISTED,
        LineTotal       AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * (1 - DiscountPercent / 100.0))) PERSISTED,
        PriceSource     NVARCHAR(20)  NOT NULL CONSTRAINT DF_SalesDocumentLines_PriceSource DEFAULT (N'PriceList'),   -- PriceList | Manual
        UnitCostBase    DECIMAL(18,6) NULL,              -- COGS per BASE unit (base currency), snapshot at posting
        ImportRowNumber INT           NULL,              -- Excel row the line came from (traceability)
        Notes           NVARCHAR(300) NULL,
        SourceLineId    INT           NULL,              -- family pattern (conversions) - unused for now
        CONSTRAINT PK_SalesDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_SalesDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT CK_SalesDocumentLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_SalesDocumentLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_SalesDocumentLines_Price CHECK (UnitPrice >= 0),
        CONSTRAINT CK_SalesDocumentLines_Discount CHECK (DiscountPercent BETWEEN 0 AND 100),
        CONSTRAINT CK_SalesDocumentLines_PriceSource CHECK (PriceSource IN (N'PriceList', N'Manual')),
        CONSTRAINT FK_SalesDocumentLines_Document  FOREIGN KEY (DocumentId)  REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_SalesDocumentLines_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_SalesDocumentLines_ItemUnit  FOREIGN KEY (ItemUnitId)  REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_SalesDocumentLines_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id)
    );
    CREATE NONCLUSTERED INDEX IX_SalesDocumentLines_Document ON sales.SalesDocumentLines (DocumentId);
    CREATE NONCLUSTERED INDEX IX_SalesDocumentLines_Item     ON sales.SalesDocumentLines (ItemId);
    PRINT 'Created sales.SalesDocumentLines';
END
GO

IF OBJECT_ID(N'sales.SalesDocumentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocumentFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        DocumentId   INT            NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_SalesDocumentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_SalesDocumentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_SalesDocumentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_SalesDocumentFiles_Document  FOREIGN KEY (DocumentId) REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_SalesDocumentFiles_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_SalesDocumentFiles_Document ON sales.SalesDocumentFiles (DocumentId);
    PRINT 'Created sales.SalesDocumentFiles';
END
GO

IF OBJECT_ID(N'sales.SalesDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Imported | Posted | Cancelled | FileAdded | FileDeleted
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_SalesDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_SalesDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_SalesDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_SalesDocumentAudit_Document ON sales.SalesDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created sales.SalesDocumentAudit';
END
GO

-- Import logs: PriceListId becomes optional (stock-mode imports have no price list) and InvoiceId points to real invoices.
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'sales.InvoiceImportLogs') AND name = N'PriceListId' AND is_nullable = 0)
BEGIN
    ALTER TABLE sales.InvoiceImportLogs ALTER COLUMN PriceListId INT NULL;
    PRINT 'sales.InvoiceImportLogs.PriceListId is now nullable (stock-mode imports)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_InvoiceImportLogs_Invoice')
BEGIN
    ALTER TABLE sales.InvoiceImportLogs WITH CHECK
        ADD CONSTRAINT FK_InvoiceImportLogs_Invoice FOREIGN KEY (InvoiceId) REFERENCES sales.SalesDocuments (Id);
    PRINT 'Added FK sales.InvoiceImportLogs.InvoiceId -> sales.SalesDocuments';
END
GO

-- RE-CREATED (script 14): same signature; @PriceListId may be NULL; an @InvoiceId must exist and gets an "Imported" audit row.
CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Log
    @BranchId       INT,
    @WarehouseId    INT,
    @PriceListId    INT          = NULL,
    @FileName       NVARCHAR(255),
    @TotalRows      INT,
    @ImportedRows   INT,
    @WarningRows    INT,
    @RejectedRows   INT,
    @DraftReference NVARCHAR(50) = NULL,
    @InvoiceId      INT          = NULL,
    @ImportedBy     INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 61000, 'File name is required.', 1;
    IF @InvoiceId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @InvoiceId)
        THROW 61000, 'Invoice not found.', 1;

    INSERT INTO sales.InvoiceImportLogs (InvoiceId, DraftReference, BranchId, WarehouseId, PriceListId, FileName,
                                         TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
    VALUES (@InvoiceId, NULLIF(LTRIM(RTRIM(@DraftReference)), N''), @BranchId, @WarehouseId, @PriceListId, LTRIM(RTRIM(@FileName)),
            ISNULL(@TotalRows, 0), ISNULL(@ImportedRows, 0), ISNULL(@WarningRows, 0), ISNULL(@RejectedRows, 0), @ImportedBy);
    SET @NewId = SCOPE_IDENTITY();

    IF @InvoiceId IS NOT NULL
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Imported', N'Excel import: ' + LTRIM(RTRIM(@FileName)) + N' (' + CAST(ISNULL(@ImportedRows, 0) AS NVARCHAR(10)) + N' row(s))', @ImportedBy);
END
GO

IF TYPE_ID(N'sales.tvp_SalesDocumentLine') IS NULL
BEGIN
    CREATE TYPE sales.tvp_SalesDocumentLine AS TABLE
    (
        LineNumber      INT           NOT NULL PRIMARY KEY,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        WarehouseId     INT           NOT NULL,
        ExpiryDate      DATE          NULL,
        Quantity        INT           NOT NULL,
        UnitPrice       DECIMAL(18,4) NULL,       -- NULL = price list price; a value is kept only with @AllowPriceOverride = 1
        DiscountPercent DECIMAL(9,4)  NULL,       -- NULL = 0
        ImportRowNumber INT           NULL,
        Notes           NVARCHAR(300) NULL
    );
    PRINT 'Created type sales.tvp_SalesDocumentLine';
END
GO

/* ================================================================== 2. Search / Get / rate helper */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Search
    @DocumentTypeCode NVARCHAR(20) = N'SINV',  -- SO | SINV | SRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, reference, client code/name, notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @ClientId         INT          = NULL,
    @SalesmanId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | ClientName | Status | TotalAmount | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'ClientName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.DueDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName,
           d.SalesmanId, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListName, d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.ReferenceNo, d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Sales'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.ReferenceNo LIKE N'%' + @Search + N'%'
           OR cl.PartyCode LIKE N'%' + @Search + N'%' OR cl.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@ClientId IS NULL OR d.ClientId = @ClientId)
      AND (@SalesmanId IS NULL OR d.SalesmanId = @SalesmanId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'ClientName' THEN cl.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'ClientName' THEN cl.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: header, lines, file metadata, audit trail.
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.DueDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Phone AS ClientPhone, cl.Email AS ClientEmail, cl.Address AS ClientAddress,
           d.SalesmanId, sm.PartyCode AS SalesmanCode, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListCode, pl.PriceListName,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.ReferenceNo, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalCostBase,
           d.SourceDocumentId,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal, l.PriceSource,
           l.UnitCostBase, l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           SystemPrice = masterdata.fn_GetUnitPrice(l.ItemUnitId, d.PriceListId, d.BranchId)   -- current price list price (info)
    FROM sales.SalesDocumentLines l
    INNER JOIN sales.SalesDocuments d   ON d.Id = l.DocumentId
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.SalesDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.SalesDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

-- Rate the page shows (and pre-fills) for a price list currency: 1 row (Rate NULL when none is defined).
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ResolveRate
    @PriceListId INT,
    @RateType    TINYINT = 1,
    @AsOfDate    DATE    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    SELECT pl.Id AS PriceListId, pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(pl.CurrencyId, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = pl.CurrencyId AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE pl.Id = @PriceListId;
END
GO

/* ================================================================== 3. Validation helper (header + lines) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @DueDate            DATE,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT,
    @PriceListId        INT,
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),          -- NULL = resolve from the rates table
    @MaxDiscountPercent DECIMAL(9,4),
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @CurrencyId         INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Sales' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 64008, 'Document type not found, inactive, or not a sales document.', 1;

    IF @DocumentDate IS NULL THROW 64000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 64000, 'Document Date cannot be in the future.', 1;
    IF @DueDate IS NOT NULL AND @DueDate < @DocumentDate THROW 64000, 'Due Date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 64008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 64008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @ClientId IS NULL THROW 64000, 'Client is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1 AND IsActive = 1)
        THROW 64008, 'Client not found, inactive, or not flagged as a client.', 1;
    IF @SalesmanId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SalesmanId AND IsSalesman = 1 AND IsActive = 1)
        THROW 64008, 'Salesman not found, inactive, or not flagged as a salesman.', 1;
    IF @PriceListId IS NULL THROW 64000, 'Price List is required.', 1;

    SELECT @CurrencyId = CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 64008, 'Price list not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 64008, 'The price list currency is inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 64000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 64000, 'Exchange rate must be greater than zero.', 1;

    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;   -- base currency: always 1
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 64008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
END
GO

/* ================================================================== 4. Save (create or update a DRAFT) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,    -- NULL = create
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,    -- NULL = from the rates table at the document date
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,       -- user holds sales.invoices.priceoverride
    @MaxDiscountPercent DECIMAL(9,4)   = 100,     -- configuration Sales:MaxDiscountPercent
    @DraftReference     NVARCHAR(50)   = NULL,    -- links the Excel import logs written before the first save
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT, @Rate DECIMAL(18,6);
    EXEC sales.usp_SalesDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
         @PriceListId, @RateType, @ExchangeRate, @MaxDiscountPercent, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 64000, 'The document type cannot be changed.', 1;
    END

    -- Resolve prices: price list price unless a manual price is allowed and given.
    DECLARE @Priced TABLE
    (
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, WarehouseId INT, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    CROSS APPLY (SELECT masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) AS Price) sp;

    DECLARE @NoPrice NVARCHAR(400);
    SELECT TOP (1) @NoPrice = N'Line ' + CAST(p.LineNumber AS NVARCHAR(10)) + N': no selling price for ' + i.ItemCode + N' (' + ut.UnitTypeName
                              + N') in price list ' + pl.PriceListName + N'. Add the price or enter a manual price (requires the price override permission).'
    FROM @Priced p
    INNER JOIN inventory.Items i       ON i.Id = p.ItemId
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = @PriceListId
    WHERE p.UnitPrice IS NULL
    ORDER BY p.LineNumber;
    IF @NoPrice IS NOT NULL THROW 64011, @NoPrice, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT;

            INSERT INTO sales.SalesDocuments (DocumentTypeId, DocumentNumber, DocumentDate, DueDate, BranchId, WarehouseId, ClientId, SalesmanId,
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE sales.SalesDocuments
            SET DocumentDate = @DocumentDate, DueDate = @DueDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                ClientId = @ClientId, SalesmanId = @SalesmanId, PriceListId = @PriceListId, CurrencyId = @CurrencyId,
                RateType = @RateType, ExchangeRate = @Rate, ReferenceNo = @ReferenceNo, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                              UnitPrice, DiscountPercent, PriceSource, ImportRowNumber, Notes)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, p.WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula,
               p.UnitPrice, p.DiscountPercent,
               CASE WHEN p.SystemPrice IS NULL OR p.UnitPrice <> p.SystemPrice THEN N'Manual' ELSE N'PriceList' END,
               p.ImportRowNumber, p.Notes
        FROM @Priced p;

        -- Totals (invoice currency) + base-currency equivalent. TotalDiscount = Subtotal - TotalAmount so they always reconcile.
        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        -- Link the import logs written before the first save (client-side draft reference) and audit them once.
        IF @DraftReference IS NOT NULL
        BEGIN
            DECLARE @NewLogs TABLE (Id INT PRIMARY KEY, FileName NVARCHAR(255), ImportedRows INT);
            INSERT INTO @NewLogs (Id, FileName, ImportedRows)
            SELECT Id, FileName, ImportedRows FROM sales.InvoiceImportLogs WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;

            EXEC sales.usp_InvoiceImport_AttachInvoice @DraftReference, @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            SELECT @Id, N'Imported', N'Excel import: ' + FileName + N' (' + CAST(ImportedRows AS NVARCHAR(10)) + N' row(s))', @UserId
            FROM @NewLogs ORDER BY Id;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. Post (ledger + COGS + number) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocumentLines WHERE DocumentId = @Id)
            THROW 64009, 'The document has no lines. Import at least one item before posting.', 1;

        -- Masters must still be valid at posting time.
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

        -- Invoices (stock out) cannot exceed the stock on hand per item + warehouse.
        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT;

        -- COGS snapshot per line (average cost per base unit at posting); returns keep a given cost when present.
        UPDATE l SET UnitCostBase = ISNULL(CASE WHEN @Direction = 1 THEN l.UnitCostBase END, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
        FROM sales.SalesDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        UPDATE d
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            TotalCostBase = ISNULL(x.Cost, 0), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT SUM(CONVERT(DECIMAL(18,2), QuantityBase * ISNULL(UnitCostBase, 0))) AS Cost FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM sales.SalesDocumentLines WHERE DocumentId = @Id);
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Cancel (reversal) / Delete draft */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Cancelling a document that ADDED stock (sales return) removes it again: it must still be there.
        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 64006, 'Document not found.', 1;
    IF @Status <> 1 THROW 64005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE sales.InvoiceImportLogs SET InvoiceId = NULL WHERE InvoiceId = @Id;   -- keep the import history
        DELETE FROM sales.SalesDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Attachments */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @DocumentId) THROW 64006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 64000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 64000, 'The file is empty.', 1;

    INSERT INTO sales.SalesDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM sales.SalesDocumentFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM sales.SalesDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    DELETE FROM sales.SalesDocumentFiles WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 8. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'sales.invoices.view',   N'View Sales Invoices',   N'Sales', N'See sales invoices.',                                 620),
        (N'sales.invoices.create', N'Create Sales Invoices', N'Sales', N'Create and edit draft sales invoices.',               630),
        (N'sales.invoices.post',   N'Post Sales Invoices',   N'Sales', N'Post sales invoices (removes stock, assigns number).', 640),
        (N'sales.invoices.cancel', N'Cancel Sales Invoices', N'Sales', N'Cancel posted sales invoices (stock reversal).',      650),
        (N'sales.invoices.delete', N'Delete Sales Invoices', N'Sales', N'Delete draft sales invoices.',                        660)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code IN (N'sales.invoices.view', N'sales.invoices.create', N'sales.invoices.post', N'sales.invoices.cancel', N'sales.invoices.delete')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'sales.invoices.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 9. Demo client (only when no client exists) + report */

IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE IsClient = 1)
BEGIN
    DECLARE @Pl INT = (SELECT TOP (1) Id FROM masterdata.PriceLists WHERE IsActive = 1 ORDER BY Id);
    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, DefaultPriceListId, IsActive)
    VALUES (N'CLI-0001', N'Walk-in Customer', 0, 1, 0, 0, @Pl, 1);
    PRINT 'Seeded client CLI-0001 Walk-in Customer';
END
GO

SELECT Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberOnPost FROM inventory.DocumentTypes WHERE Family = N'Sales' ORDER BY Code;
SELECT p.Code, p.Module, p.SortOrder FROM security.Permissions p WHERE p.Code LIKE N'sales.%' ORDER BY p.SortOrder;
EXEC sales.usp_SalesDocument_ResolveRate @PriceListId = 1, @RateType = 1;
PRINT 'Sales documents (Sales Invoice) are ready.';
GO
