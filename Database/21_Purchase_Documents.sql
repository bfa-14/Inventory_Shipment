/* =====================================================================================
   Inventory_Shipment - 21: PURCHASE document family + Shortages report

   Family Purchase (schema purchase), one header + one lines table, discriminated by inventory.DocumentTypes:
     PO   Purchase Order   - no stock effect. Draft -> Posted (= confirmed / open) -> Closed (fully received or
                             closed manually) | Cancelled (only while nothing was received against it).
     PINV Purchase Invoice - stock +, cost. Draft -> Posted (ledger, moving average, item last cost/supplier,
                             PO received quantities) -> Cancelled (reversal; PO re-opened).
     PRET Purchase Return  - stock -. Created from a posted PINV (or from scratch). Draft -> Posted (needs stock,
                             cost = the invoice cost) -> Cancelled (reversal).
   Money: the supplier CURRENCY (default = supplier's DefaultCurrencyId, else base) with RateType + ExchangeRate
          (1 base = Rate x currency; auto from masterdata.fn_GetRate, editable). Lines are priced in the document
          currency; the ledger cost per base unit in USD = UnitPrice x (1 - Disc%) / PackingFormula / Rate.
          A blank line price on PO/PINV = the item's last cost converted to the document currency.
   Conversions: usp_PurchaseDocument_CreateFromSource  PO -> PINV (remaining quantities), PINV -> PRET (invoiced -
          returned); SourceDocumentId / SourceLineId keep the link; ReceivedQuantityBase (PO lines) and
          ReturnedQuantityBase (PINV lines) track what was consumed.
   One document = one warehouse (lines take the header warehouse).

   Objects: purchase.PurchaseDocuments / PurchaseDocumentLines / PurchaseDocumentFiles / PurchaseDocumentAudit,
            purchase.tvp_PurchaseDocumentLine, usp_PurchaseDocument_Search / _Get (5 result sets: header, lines,
            files, audit, linked documents) / _ValidateInput / _Save / _Post / _Cancel / _Close / _Delete /
            _CreateFromSource, usp_PurchaseDocumentFile_Add / _Get / _Delete,
            masterdata.usp_ExchangeRate_Resolve (rate for a currency), inventory.usp_Shortage_Report.

   Shortages (general formula until the customer's formulas arrive), per item + warehouse:
     Available = OnHand + Incoming (open PO remaining, base units, same warehouse)
     Short when Available < MinQuantity;  ShortageBase = Min - Available
     SuggestedBase = ISNULL(Max, Min) - Available, rounded UP to the purchase unit (SuggestedQty in that unit)
     AvgDailySales = net Sales-family outflow of the last @DaysForAverage days / days; DaysOfCover = OnHand / AvgDailySales
     Supplier = item DefaultSupplierId, else LastSupplierId.  Evaluated at the item's default warehouse and at every
     warehouse where the item has movements (filters: branch, warehouse, family, brand, supplier, search).

   Error numbers 65xxx: 65000 validation ("Line N: ...")  65004 concurrency  65005 not a draft  65006 not found
     65007 insufficient stock  65008 master data / rate  65009 no lines  65010 invalid status  65011 source document
     problem (not posted, other supplier, quantity above remaining, already referenced)
   Permissions (module Purchase): purchase.orders.* 1000-1040, purchase.invoices.* 1060-1100, purchase.returns.* 1120-1160;
     (module Inventory) inventory.shortages.view 950.  Manager gets the .view ones.

   Requires 19 and 20. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.usp_Item_ApplyReceipts', N'P') IS NULL OR TYPE_ID(N'inventory.tvp_ItemReceipt') IS NULL
BEGIN
    RAISERROR ('Run scripts 19 and 20 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'purchase') IS NULL EXEC (N'CREATE SCHEMA purchase AUTHORIZATION dbo');
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'purchase.PurchaseDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocuments
    (
        Id                INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId    INT            NOT NULL,     -- PO | PINV | PRET
        DocumentNumber    NVARCHAR(30)   NULL,
        DocumentDate      DATE           NOT NULL,
        ExpectedDate      DATE           NULL,         -- PO: expected delivery; PINV: due date
        BranchId          INT            NOT NULL,
        WarehouseId       INT            NOT NULL,
        SupplierId        INT            NOT NULL,     -- masterdata.Parties (IsSupplier) - name matters: party type guard
        CurrencyId        INT            NOT NULL,
        RateType          TINYINT        NOT NULL CONSTRAINT DF_PurchaseDocuments_RateType DEFAULT (1),
        ExchangeRate      DECIMAL(18,6)  NOT NULL CONSTRAINT DF_PurchaseDocuments_Rate DEFAULT (1),
        SupplierReference NVARCHAR(100)  NULL,         -- supplier's order / invoice number
        Notes             NVARCHAR(1000) NULL,
        Status            TINYINT        NOT NULL CONSTRAINT DF_PurchaseDocuments_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled, 4 Closed (PO)
        TotalItems        INT            NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalItems DEFAULT (0),
        TotalQuantity     INT            NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalQuantity DEFAULT (0),
        Subtotal          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_Subtotal DEFAULT (0),
        TotalDiscount     DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalDiscount DEFAULT (0),
        TotalAmount       DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalAmount DEFAULT (0),      -- document currency
        TotalAmountBase   DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalAmountBase DEFAULT (0),  -- base currency
        SourceDocumentId  INT            NULL,         -- PINV <- PO, PRET <- PINV
        PostedAtUtc       DATETIME2(3)   NULL,
        PostedBy          INT            NULL,
        CancelledAtUtc    DATETIME2(3)   NULL,
        CancelledBy       INT            NULL,
        CancelReason      NVARCHAR(300)  NULL,
        ClosedAtUtc       DATETIME2(3)   NULL,
        ClosedBy          INT            NULL,
        CloseReason       NVARCHAR(300)  NULL,
        CreatedAtUtc      DATETIME2(3)   NOT NULL CONSTRAINT DF_PurchaseDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy         INT            NULL,
        UpdatedAtUtc      DATETIME2(3)   NULL,
        UpdatedBy         INT            NULL,
        RowVersion        ROWVERSION     NOT NULL,
        CONSTRAINT PK_PurchaseDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_PurchaseDocuments_Status CHECK (Status IN (1, 2, 3, 4)),
        CONSTRAINT CK_PurchaseDocuments_RateType CHECK (RateType IN (1, 2, 3)),
        CONSTRAINT CK_PurchaseDocuments_Rate CHECK (ExchangeRate > 0),
        CONSTRAINT FK_PurchaseDocuments_Type        FOREIGN KEY (DocumentTypeId)   REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_PurchaseDocuments_Branch      FOREIGN KEY (BranchId)         REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_PurchaseDocuments_Warehouse   FOREIGN KEY (WarehouseId)      REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_PurchaseDocuments_Supplier    FOREIGN KEY (SupplierId)       REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_PurchaseDocuments_Currency    FOREIGN KEY (CurrencyId)       REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_PurchaseDocuments_Source      FOREIGN KEY (SourceDocumentId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseDocuments_CreatedBy   FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_UpdatedBy   FOREIGN KEY (UpdatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_PostedBy    FOREIGN KEY (PostedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_CancelledBy FOREIGN KEY (CancelledBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_ClosedBy    FOREIGN KEY (ClosedBy)         REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_PurchaseDocuments_Number ON purchase.PurchaseDocuments (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_TypeDate   ON purchase.PurchaseDocuments (DocumentTypeId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_TypeStatus ON purchase.PurchaseDocuments (DocumentTypeId, Status);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_Supplier   ON purchase.PurchaseDocuments (SupplierId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_Source     ON purchase.PurchaseDocuments (SourceDocumentId) WHERE SourceDocumentId IS NOT NULL;
    PRINT 'Created purchase.PurchaseDocuments';
END
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocumentLines
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        DocumentId           INT           NOT NULL,
        LineNumber           INT           NOT NULL,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,
        WarehouseId          INT           NOT NULL,
        ExpiryDate           DATE          NULL,
        Quantity             INT           NOT NULL,
        PackingFormula       INT           NOT NULL,
        QuantityBase         AS (Quantity * PackingFormula) PERSISTED,
        UnitPrice            DECIMAL(18,4) NOT NULL,          -- per unit, document currency
        DiscountPercent      DECIMAL(9,4)  NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Discount DEFAULT (0),
        LineDiscount         AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * DiscountPercent / 100.0)) PERSISTED,
        LineTotal            AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * (1 - DiscountPercent / 100.0))) PERSISTED,
        UnitCostBase         DECIMAL(18,6) NULL,              -- per BASE unit, base currency (set at posting)
        ReceivedQuantityBase INT           NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Received DEFAULT (0),  -- PO lines: invoiced so far
        ReturnedQuantityBase INT           NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Returned DEFAULT (0),  -- PINV lines: returned so far
        ImportRowNumber      INT           NULL,
        Notes                NVARCHAR(300) NULL,
        SourceLineId         INT           NULL,
        CONSTRAINT PK_PurchaseDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT CK_PurchaseDocumentLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_PurchaseDocumentLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_PurchaseDocumentLines_Price CHECK (UnitPrice >= 0),
        CONSTRAINT CK_PurchaseDocumentLines_Discount CHECK (DiscountPercent BETWEEN 0 AND 100),
        CONSTRAINT FK_PurchaseDocumentLines_Document   FOREIGN KEY (DocumentId)   REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseDocumentLines_Item       FOREIGN KEY (ItemId)       REFERENCES inventory.Items (Id),
        CONSTRAINT FK_PurchaseDocumentLines_ItemUnit   FOREIGN KEY (ItemUnitId)   REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_PurchaseDocumentLines_Warehouse  FOREIGN KEY (WarehouseId)  REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_PurchaseDocumentLines_SourceLine FOREIGN KEY (SourceLineId) REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_Document ON purchase.PurchaseDocumentLines (DocumentId);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_Item     ON purchase.PurchaseDocumentLines (ItemId);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_Source   ON purchase.PurchaseDocumentLines (SourceLineId) WHERE SourceLineId IS NOT NULL;
    PRINT 'Created purchase.PurchaseDocumentLines';
END
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocumentFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        DocumentId   INT            NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_PurchaseDocumentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_PurchaseDocumentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_PurchaseDocumentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_PurchaseDocumentFiles_Document  FOREIGN KEY (DocumentId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseDocumentFiles_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentFiles_Document ON purchase.PurchaseDocumentFiles (DocumentId);
    PRINT 'Created purchase.PurchaseDocumentFiles';
END
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Imported | Posted | Cancelled | Closed | FileAdded | FileDeleted
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_PurchaseDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_PurchaseDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_PurchaseDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentAudit_Document ON purchase.PurchaseDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created purchase.PurchaseDocumentAudit';
END
GO

IF TYPE_ID(N'purchase.tvp_PurchaseDocumentLine') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PurchaseDocumentLine AS TABLE
    (
        LineNumber      INT           NOT NULL PRIMARY KEY,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        WarehouseId     INT           NOT NULL,       -- ignored: the header warehouse is used
        ExpiryDate      DATE          NULL,
        Quantity        INT           NOT NULL,
        UnitPrice       DECIMAL(18,4) NULL,           -- NULL = item last cost converted to the document currency (0 when none)
        DiscountPercent DECIMAL(9,4)  NULL,
        ImportRowNumber INT           NULL,
        Notes           NVARCHAR(300) NULL,
        SourceLineId    INT           NULL            -- PO line (for PINV) / PINV line (for PRET)
    );
    PRINT 'Created type purchase.tvp_PurchaseDocumentLine';
END
GO

/* ================================================================== 2. Rate helper (any currency) */

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Resolve
    @CurrencyId INT,
    @RateType   TINYINT = 1,
    @AsOfDate   DATE    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    SELECT c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(c.Id, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.Currencies c
    WHERE c.Id = @CurrencyId;
END
GO

/* ================================================================== 3. Search / Get */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,     -- PO | PINV | PRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, supplier reference, supplier code/name, notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @SupplierId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled | 4 Closed
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | SupplierName | Status | TotalAmount | CreatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.SupplierReference, d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND d.TotalQuantity > 0
                                  THEN CAST(100.0 * (SELECT SUM(ReceivedQuantityBase) FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) / d.TotalQuantity AS DECIMAL(5,1)) END,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc, d.ClosedAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Purchase'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.SupplierReference LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
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

-- Five result sets: header, lines, files, audit, linked documents (source + children).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, l.ReceivedQuantityBase, l.ReturnedQuantityBase,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- Linked documents: the source (Relation = 'Source') and everything created from this one (Relation = 'Child').
    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;
END
GO

/* ================================================================== 4. Validation helper */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE,
    @BranchId           INT,
    @WarehouseId        INT,
    @SupplierId         INT,
    @CurrencyId         INT,             -- NULL = supplier default currency, else base
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),   -- NULL = resolve
    @MaxDiscountPercent DECIMAL(9,4),
    @SourceDocumentId   INT,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @ResolvedCurrencyId INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Purchase' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 65008, 'Document type not found, inactive, or not a purchase document.', 1;

    IF @DocumentDate IS NULL THROW 65000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 65000, 'Document Date cannot be in the future.', 1;
    IF @ExpectedDate IS NOT NULL AND @ExpectedDate < @DocumentDate THROW 65000, 'Expected / due date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 65008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 65008, 'The warehouse must be an active warehouse of the selected branch.', 1;
    IF @SupplierId IS NULL THROW 65000, 'Supplier is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 65008, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    SET @ResolvedCurrencyId = COALESCE(@CurrencyId,
                                       (SELECT DefaultCurrencyId FROM masterdata.Parties WHERE Id = @SupplierId),
                                       (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1));
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsActive = 1)
        THROW 65008, 'Currency not found or inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 65000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 65000, 'Exchange rate must be greater than zero.', 1;
    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@ResolvedCurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 65008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    -- Source document rules.
    IF @SourceDocumentId IS NOT NULL
    BEGIN
        DECLARE @SrcType NVARCHAR(20), @SrcStatus TINYINT, @SrcSupplier INT, @SrcBranch INT;
        SELECT @SrcType = dt.Code, @SrcStatus = d.Status, @SrcSupplier = d.SupplierId, @SrcBranch = d.BranchId
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceDocumentId;
        IF @SrcType IS NULL THROW 65011, 'Source document not found.', 1;
        IF (@DocumentTypeCode = N'PINV' AND @SrcType <> N'PO') OR (@DocumentTypeCode = N'PRET' AND @SrcType <> N'PINV') OR @DocumentTypeCode = N'PO'
            THROW 65011, 'A purchase invoice can only come from a purchase order and a return from a purchase invoice.', 1;
        IF @SrcStatus <> 2 THROW 65011, 'The source document must be posted (and, for an order, still open).', 1;
        IF @SrcSupplier <> @SupplierId THROW 65011, 'The supplier must be the supplier of the source document.', 1;
        IF @SrcBranch <> @BranchId THROW 65011, 'The branch must be the branch of the source document.', 1;
        IF EXISTS (SELECT 1 FROM @Lines l WHERE l.SourceLineId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines s WHERE s.Id = l.SourceLineId AND s.DocumentId = @SourceDocumentId))
            THROW 65011, 'A line refers to a source line that does not belong to the source document.', 1;
    END

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 65000, @Msg, 1;
END
GO

/* ================================================================== 5. Save (draft) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @SupplierId         INT,
    @CurrencyId         INT            = NULL,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @SupplierReference  NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @SourceDocumentId   INT            = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines: header warehouse; blank price = item last cost (USD per base unit) converted to the document currency per unit.
        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, @WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.UnitCostBase END,      -- returns carry the invoice cost
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Post */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        -- Source consumption checks (posted documents only count).
        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = @Id AND l.LineNumber = x.LineNumber
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = @Id AND l.LineNumber = x.LineNumber
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        -- Returns remove stock: it must be there.
        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- Cost per base unit in the base currency.
        UPDATE l
        SET UnitCostBase = CASE WHEN @TypeCode = N'PRET' THEN ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
                                ELSE (l.UnitPrice * (1 - l.DiscountPercent / 100.0)) / l.PackingFormula / @Rate END
        FROM purchase.PurchaseDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0) FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        -- Consume the source: PO received quantities (close the PO when everything is in) / PINV returned quantities.
        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N' (order confirmed)' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Cancel / Close / Delete */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId, @Number = d.DocumentNumber
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Nothing may still depend on this document.
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;

        DECLARE @Msg NVARCHAR(400);
        IF @Direction = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentId = @Id AND m.IsReversal = 0;

        -- Give the source its quantities back (and re-open a PO that this invoice had closed).
        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason = N'Fully received')
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Purchase orders only: stop receiving against an open order.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders can be closed.', 1;
    IF @Status <> 2 THROW 65010, 'Only open (posted) purchase orders can be closed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    UPDATE purchase.PurchaseDocuments
    SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = ISNULL(NULLIF(LTRIM(RTRIM(@Reason)), N''), N'Closed manually'),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Closed', ISNULL(@Reason, N'Closed manually'), @UserId);
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 1 THROW 65005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. Conversions: PO -> PINV, PINV -> PRET (drafts) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromSource
    @SourceId       INT,
    @TargetTypeCode NVARCHAR(20),        -- PINV (from PO) | PRET (from PINV)
    @DocumentDate   DATE = NULL,         -- default today
    @UserId         INT  = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT, @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;

    IF @SrcType IS NULL THROW 65006, 'Source document not found.', 1;
    IF @Status <> 2 THROW 65011, 'The source document must be posted and still open.', 1;
    IF NOT ((@TargetTypeCode = N'PINV' AND @SrcType = N'PO') OR (@TargetTypeCode = N'PRET' AND @SrcType = N'PINV'))
        THROW 65011, 'Purchase orders become purchase invoices; purchase invoices become purchase returns.', 1;

    -- Remaining quantity per line; when it is not a whole number of the line's unit, the new line uses the BASE unit
    -- (price converted per base unit) so nothing is over-received or over-returned.
    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate,
           c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes, l.Id
    FROM purchase.PurchaseDocumentLines l
    CROSS APPLY (SELECT Remaining = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE l.QuantityBase - l.ReturnedQuantityBase END) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;

    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 65011, 'Nothing remains to receive / return on the source document.', 1;

    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = @TargetTypeCode, @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
         @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;
END
GO

/* ================================================================== 9. Attachments */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId) THROW 65006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 65000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 65000, 'The file is empty.', 1;

    INSERT INTO purchase.PurchaseDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    DELETE FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 10. Shortages report */

CREATE OR ALTER PROCEDURE inventory.usp_Shortage_Report
    @BranchId       INT           = NULL,
    @WarehouseId    INT           = NULL,
    @ItemFamilyId   INT           = NULL,
    @BrandId        INT           = NULL,
    @SupplierId     INT           = NULL,     -- default supplier (else last supplier)
    @Search         NVARCHAR(200) = NULL,     -- item code / name
    @OnlyShortages  BIT           = 1,        -- 1 = rows where Available < Min; 0 = every evaluated item + warehouse
    @DaysForAverage INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @DaysForAverage IS NULL OR @DaysForAverage < 1 SET @DaysForAverage = 30;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@DaysForAverage, SYSUTCDATETIME());

    ;WITH pairs AS
    (
        SELECT i.Id AS ItemId, i.DefaultWarehouseId AS WarehouseId FROM inventory.Items i WHERE i.IsActive = 1
        UNION
        SELECT m.ItemId, m.WarehouseId FROM inventory.StockMovements m INNER JOIN inventory.Items i ON i.Id = m.ItemId WHERE i.IsActive = 1
    ),
    base AS
    (
        SELECT p.ItemId, p.WarehouseId,
               OnHandBase   = inventory.fn_StockOnHand(p.ItemId, p.WarehouseId),
               IncomingBase = ISNULL((SELECT SUM(l.QuantityBase - l.ReceivedQuantityBase)
                                      FROM purchase.PurchaseDocumentLines l
                                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                                      INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                                      WHERE dt.Code = N'PO' AND d.Status = 2 AND l.ItemId = p.ItemId AND l.WarehouseId = p.WarehouseId
                                        AND l.QuantityBase > l.ReceivedQuantityBase), 0),
               SoldBase     = ISNULL((SELECT SUM(-m.QuantityBase) FROM inventory.StockMovements m
                                      WHERE m.ItemId = p.ItemId AND m.WarehouseId = p.WarehouseId AND m.DocumentFamily = N'Sales' AND m.MovementDate >= @Since), 0)
        FROM pairs p
    )
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.ItemFamilyId, f.FamilyName, i.IsBivac,
           w.Id AS WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId, br.BranchName,
           x.OnHandBase, x.IncomingBase, AvailableBase = x.OnHandBase + x.IncomingBase,
           i.MinQuantity, i.MaxQuantity,
           ShortageBase  = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN i.MinQuantity - (x.OnHandBase + x.IncomingBase) ELSE 0 END,
           SuggestedBase = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN ISNULL(i.MaxQuantity, i.MinQuantity) - (x.OnHandBase + x.IncomingBase) ELSE 0 END,
           PurchaseItemUnitId = pu.Id, PurchaseUnitName = put.UnitTypeName, PurchasePackingFormula = pu.PackingFormula,
           SuggestedQty  = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity
                                THEN CEILING(CAST(ISNULL(i.MaxQuantity, i.MinQuantity) - (x.OnHandBase + x.IncomingBase) AS DECIMAL(18,4)) / pu.PackingFormula) ELSE 0 END,
           AvgDailySalesBase = CAST(x.SoldBase AS DECIMAL(18,2)) / @DaysForAverage,
           DaysOfCover = CASE WHEN x.SoldBase > 0 THEN CAST(x.OnHandBase AS DECIMAL(18,2)) * @DaysForAverage / x.SoldBase END,
           SupplierId = COALESCE(i.DefaultSupplierId, i.LastSupplierId),
           SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN i.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END,
           i.LastCost, i.AverageCost, i.LeadTimeDays, i.LastPurchaseAtUtc
    FROM base x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Brands b ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    INNER JOIN masterdata.Branches br ON br.Id = w.BranchId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = i.LastSupplierId
    OUTER APPLY (SELECT TOP (1) u.Id, u.PackingFormula, u.UnitTypeId FROM inventory.ItemUnits u WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC) pu
    LEFT  JOIN masterdata.UnitTypes put ON put.Id = pu.UnitTypeId
    WHERE w.IsActive = 1
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR w.Id = @WarehouseId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@SupplierId IS NULL OR COALESCE(i.DefaultSupplierId, i.LastSupplierId) = @SupplierId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR x.OnHandBase + x.IncomingBase < i.MinQuantity)
    ORDER BY CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN 0 ELSE 1 END, i.ItemCode, w.WarehouseCode;
END
GO

/* ================================================================== 11. Permissions + demo supplier + report */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'purchase.orders.view',     N'View Purchase Orders',     N'Purchase', N'See purchase orders.',                              1000),
        (N'purchase.orders.create',   N'Create Purchase Orders',   N'Purchase', N'Create and edit draft purchase orders.',            1010),
        (N'purchase.orders.post',     N'Post Purchase Orders',     N'Purchase', N'Confirm purchase orders (assigns the number).',     1020),
        (N'purchase.orders.cancel',   N'Cancel Purchase Orders',   N'Purchase', N'Cancel or close open purchase orders.',             1030),
        (N'purchase.orders.delete',   N'Delete Purchase Orders',   N'Purchase', N'Delete draft purchase orders.',                     1040),
        (N'purchase.invoices.view',   N'View Purchase Invoices',   N'Purchase', N'See purchase invoices.',                            1060),
        (N'purchase.invoices.create', N'Create Purchase Invoices', N'Purchase', N'Create and edit draft purchase invoices.',          1070),
        (N'purchase.invoices.post',   N'Post Purchase Invoices',   N'Purchase', N'Post purchase invoices (adds stock, sets costs).',  1080),
        (N'purchase.invoices.cancel', N'Cancel Purchase Invoices', N'Purchase', N'Cancel posted purchase invoices (stock reversal).', 1090),
        (N'purchase.invoices.delete', N'Delete Purchase Invoices', N'Purchase', N'Delete draft purchase invoices.',                   1100),
        (N'purchase.returns.view',    N'View Purchase Returns',    N'Purchase', N'See purchase returns.',                             1120),
        (N'purchase.returns.create',  N'Create Purchase Returns',  N'Purchase', N'Create and edit draft purchase returns.',           1130),
        (N'purchase.returns.post',    N'Post Purchase Returns',    N'Purchase', N'Post purchase returns (removes stock).',            1140),
        (N'purchase.returns.cancel',  N'Cancel Purchase Returns',  N'Purchase', N'Cancel posted purchase returns (stock reversal).',  1150),
        (N'purchase.returns.delete',  N'Delete Purchase Returns',  N'Purchase', N'Delete draft purchase returns.',                    1160),
        (N'inventory.shortages.view', N'View Shortages',           N'Inventory', N'See the shortage report and create purchase orders from it.', 950)
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
WHERE (p.Code LIKE N'purchase.%' OR p.Code = N'inventory.shortages.view')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'purchase.orders.view', N'purchase.invoices.view', N'purchase.returns.view', N'inventory.shortages.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- The seeded supplier becomes the default supplier of items that have none (demo convenience).
UPDATE i SET DefaultSupplierId = s.Id
FROM inventory.Items i
CROSS APPLY (SELECT TOP (1) Id FROM masterdata.Parties WHERE IsSupplier = 1 AND IsActive = 1 ORDER BY Id) s
WHERE i.DefaultSupplierId IS NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE IsSupplier = 1 AND IsActive = 1 AND Id <> s.Id);
GO

SELECT Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, DefaultPricing FROM inventory.DocumentTypes WHERE Family = N'Purchase' ORDER BY Code;
SELECT p.Code, p.Module, p.SortOrder FROM security.Permissions p WHERE p.Code LIKE N'purchase.%' OR p.Code = N'inventory.shortages.view' ORDER BY p.SortOrder;
EXEC inventory.usp_Shortage_Report @OnlyShortages = 0;
PRINT 'Purchase documents (PO / PINV / PRET) and the Shortages report are ready.';
GO
