/* =====================================================================================
   Inventory_Shipment - 15: Inventory In / Out documents + Stock Movements ledger
   (first document family; skeleton shared by the future Purchase and Sales families)

   Objects (schema inventory unless noted):
     DocumentTypes            - CONFIGURATION of every document kind in the system (code, family,
                                stock direction, numbering prefix/sequence, number at draft or at post,
                                reason required). Seeded with the 8 agreed types.
     StockReasons             - reasons for Inventory In / Out (opening balance, correction, damage...)
     StockMovements           - THE LEDGER: every posted document of any family writes signed base-unit
                                quantities here; Stock Balance / Movement / Shortage read only this table.
     fn_StockOnHand, vw_StockBalance
     StockDocuments / StockDocumentLines / StockDocumentFiles / StockDocumentAudit
     tvp_StockDocumentLine, usp_StockDocument_Search / _Get / _Save / _Post / _Cancel / _Delete,
     usp_StockDocumentFile_Add / _Get / _Delete, usp_DocumentType_List / _NextNumber, usp_StockReason_Lookup
     inventory.usp_Item_Search / usp_Item_Get  - RE-CREATED: OnHand / LastCost / AverageCost now come from the ledger
     sales.usp_InvoiceImport_Validate          - RE-CREATED: @PriceListId optional (stock documents import
                                                 quantities + costs without a price list)

   Document lifecycle: Draft (editable, no stock effect) -> Posted (stock movements written, read-only)
                       -> Cancelled (reversal movements written). Drafts may be deleted; posted never.
   Quantities are pieces; lines store Quantity in the chosen unit + a snapshot of PackingFormula;
   the ledger stores QuantityBase = Quantity x PackingFormula (signed by the type's StockDirection).
   Costs: Inventory In lines carry a Unit Cost in the BASE currency (per unit); the ledger stores the
   cost per base unit. Inventory Out lines take the current average cost automatically.
   Numbering: DocumentTypes.NumberOnPost = 0 -> number assigned at first save (drafts get a number);
              = 1 -> drafts show DRAFT and the number is assigned when posting (gapless).

   Error numbers (read by the API):
     62000 validation (incl. per-line messages)   62004 concurrency   62005 document is not a draft
     62006 not found   62007 insufficient stock   62008 related master data missing/inactive
     62009 document has no lines   62010 invalid status transition (already posted / cancelled)

   Requires 07 (Warehouses), 08 (Currencies), 11 (Items), 12 (Price lists), 14 (Import engine).
   Idempotent. Table types cannot be altered - drop dependent procs first if you change one.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL OR OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL OR OBJECT_ID(N'sales.usp_InvoiceImport_Validate', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 07, 08, 11, 12 and 14 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Document type configuration */

IF OBJECT_ID(N'inventory.DocumentTypes', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.DocumentTypes
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        Code           NVARCHAR(20)  NOT NULL,     -- INV_IN, INV_OUT, PO, PINV, PRET, SO, SINV, SRET
        Name           NVARCHAR(100) NOT NULL,
        Family         NVARCHAR(20)  NOT NULL,     -- Inventory | Purchase | Sales
        StockDirection SMALLINT      NOT NULL,     -- +1 adds stock, -1 removes, 0 no effect (orders)
        NumberPrefix   NVARCHAR(10)  NOT NULL,
        NextNumber     INT           NOT NULL CONSTRAINT DF_DocumentTypes_NextNumber DEFAULT (1),
        NumberLength   TINYINT       NOT NULL CONSTRAINT DF_DocumentTypes_NumberLength DEFAULT (6),
        NumberOnPost   BIT           NOT NULL CONSTRAINT DF_DocumentTypes_NumberOnPost DEFAULT (0),
        RequiresReason BIT           NOT NULL CONSTRAINT DF_DocumentTypes_RequiresReason DEFAULT (0),
        IsActive       BIT           NOT NULL CONSTRAINT DF_DocumentTypes_IsActive DEFAULT (1),
        UpdatedAtUtc   DATETIME2(3)  NULL,
        UpdatedBy      INT           NULL,
        RowVersion     ROWVERSION    NOT NULL,
        CONSTRAINT PK_DocumentTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_DocumentTypes_Code UNIQUE (Code),
        CONSTRAINT CK_DocumentTypes_Family CHECK (Family IN (N'Inventory', N'Purchase', N'Sales')),
        CONSTRAINT CK_DocumentTypes_Direction CHECK (StockDirection IN (-1, 0, 1)),
        CONSTRAINT CK_DocumentTypes_NumberLength CHECK (NumberLength BETWEEN 3 AND 10)
    );
    PRINT 'Created inventory.DocumentTypes';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES
    (N'INV_IN',  N'Inventory In',     N'Inventory',  1, N'IN-',   0, 1),
    (N'INV_OUT', N'Inventory Out',    N'Inventory', -1, N'OUT-',  0, 1),
    (N'PO',      N'Purchase Order',   N'Purchase',   0, N'PO-',   0, 0),
    (N'PINV',    N'Purchase Invoice', N'Purchase',   1, N'PINV-', 1, 0),
    (N'PRET',    N'Purchase Return',  N'Purchase',  -1, N'PRET-', 1, 0),
    (N'SO',      N'Sales Order',      N'Sales',      0, N'SO-',   0, 0),
    (N'SINV',    N'Sales Invoice',    N'Sales',     -1, N'INV-',  1, 0),
    (N'SRET',    N'Sales Return',     N'Sales',      1, N'SRET-', 1, 0)
) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

-- Atomic next number for a document type: prefix + zero-padded sequence (IN-000001).
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Taken TABLE (Prefix NVARCHAR(10), Number INT, Len TINYINT);

    UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
    SET NextNumber = NextNumber + 1
    OUTPUT deleted.NumberPrefix, deleted.NextNumber, deleted.NumberLength INTO @Taken
    WHERE Code = @Code AND IsActive = 1;

    IF NOT EXISTS (SELECT 1 FROM @Taken)
        THROW 62008, 'Document type not found or inactive.', 1;

    SELECT @DocumentNumber = Prefix + RIGHT(REPLICATE(N'0', Len) + CAST(Number AS NVARCHAR(10)), Len) FROM @Taken;
END
GO

/* ================================================================== 2. Stock reasons */

IF OBJECT_ID(N'inventory.StockReasons', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockReasons
    (
        Id         INT IDENTITY(1,1) NOT NULL,
        ReasonCode NVARCHAR(20)  NOT NULL,
        ReasonName NVARCHAR(100) NOT NULL,
        AppliesTo  NVARCHAR(10)  NOT NULL,   -- In | Out | Both
        IsActive   BIT           NOT NULL CONSTRAINT DF_StockReasons_IsActive DEFAULT (1),
        CONSTRAINT PK_StockReasons PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_StockReasons_Code UNIQUE (ReasonCode),
        CONSTRAINT CK_StockReasons_AppliesTo CHECK (AppliesTo IN (N'In', N'Out', N'Both'))
    );
    PRINT 'Created inventory.StockReasons';
END
GO

MERGE inventory.StockReasons AS t
USING (VALUES
    (N'OPENING',  N'Opening Balance',        N'In'),
    (N'ADJ_IN',   N'Stock Correction (+)',   N'In'),
    (N'FOUND',    N'Found / Surplus',        N'In'),
    (N'TRF_IN',   N'Transfer In',            N'In'),
    (N'RET_STOCK',N'Returned to Stock',      N'In'),
    (N'ADJ_OUT',  N'Stock Correction (-)',   N'Out'),
    (N'DAMAGED',  N'Damaged',                N'Out'),
    (N'LOST',     N'Lost / Stolen',          N'Out'),
    (N'TRF_OUT',  N'Transfer Out',           N'Out'),
    (N'INT_USE',  N'Internal Use',           N'Out')
) AS s (ReasonCode, ReasonName, AppliesTo)
ON t.ReasonCode = s.ReasonCode
WHEN NOT MATCHED BY TARGET THEN INSERT (ReasonCode, ReasonName, AppliesTo) VALUES (s.ReasonCode, s.ReasonName, s.AppliesTo);
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockReason_Lookup
    @Direction SMALLINT = NULL,    -- 1 = In, -1 = Out, NULL = all
    @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ReasonCode, ReasonName, AppliesTo, IsActive
    FROM inventory.StockReasons
    WHERE (IsActive = 1 OR Id = @IncludeId)
      AND (@Direction IS NULL OR AppliesTo = N'Both'
           OR (@Direction = 1 AND AppliesTo = N'In') OR (@Direction = -1 AND AppliesTo = N'Out'))
    ORDER BY ReasonName;
END
GO

/* ================================================================== 3. Stock movements ledger */

IF OBJECT_ID(N'inventory.StockMovements', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockMovements
    (
        Id               BIGINT IDENTITY(1,1) NOT NULL,
        MovementDate     DATETIME2(3)  NOT NULL,      -- effective date (document date + posting time)
        ItemId           INT           NOT NULL,
        WarehouseId      INT           NOT NULL,
        BranchId         INT           NOT NULL,
        QuantityBase     INT           NOT NULL,      -- signed, in BASE units (+ in / - out)
        UnitCostBase     DECIMAL(18,6) NULL,          -- cost per base unit, base currency
        DocumentFamily   NVARCHAR(20)  NOT NULL,      -- Inventory | Purchase | Sales
        DocumentTypeCode NVARCHAR(20)  NOT NULL,
        DocumentId       INT           NOT NULL,
        DocumentLineId   INT           NOT NULL,
        DocumentNumber   NVARCHAR(30)  NOT NULL,
        ReasonCode       NVARCHAR(20)  NULL,
        ExpiryDate       DATE          NULL,
        IsReversal       BIT           NOT NULL CONSTRAINT DF_StockMovements_IsReversal DEFAULT (0),
        CreatedAtUtc     DATETIME2(3)  NOT NULL CONSTRAINT DF_StockMovements_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT           NULL,
        CONSTRAINT PK_StockMovements PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_StockMovements_Qty CHECK (QuantityBase <> 0),
        CONSTRAINT FK_StockMovements_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_StockMovements_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_StockMovements_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_StockMovements_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockMovements_ItemWarehouseDate ON inventory.StockMovements (ItemId, WarehouseId, MovementDate) INCLUDE (QuantityBase, UnitCostBase);
    CREATE NONCLUSTERED INDEX IX_StockMovements_WarehouseDate     ON inventory.StockMovements (WarehouseId, MovementDate) INCLUDE (ItemId, QuantityBase);
    CREATE NONCLUSTERED INDEX IX_StockMovements_Document          ON inventory.StockMovements (DocumentFamily, DocumentId);
    PRINT 'Created inventory.StockMovements';
END
GO

-- On-hand in BASE units for an item (optionally in one warehouse).
CREATE OR ALTER FUNCTION inventory.fn_StockOnHand (@ItemId INT, @WarehouseId INT)
RETURNS INT
AS
BEGIN
    RETURN ISNULL((SELECT SUM(QuantityBase) FROM inventory.StockMovements
                   WHERE ItemId = @ItemId AND (@WarehouseId IS NULL OR WarehouseId = @WarehouseId)), 0);
END
GO

-- Weighted average cost per base unit of all receipts (positive, non-reversal movements).
CREATE OR ALTER FUNCTION inventory.fn_AverageCost (@ItemId INT)
RETURNS DECIMAL(18,6)
AS
BEGIN
    RETURN (SELECT CASE WHEN SUM(QuantityBase) > 0 THEN SUM(QuantityBase * ISNULL(UnitCostBase, 0)) / SUM(QuantityBase) END
            FROM inventory.StockMovements
            WHERE ItemId = @ItemId AND QuantityBase > 0 AND IsReversal = 0);
END
GO

CREATE OR ALTER VIEW inventory.vw_StockBalance
AS
    SELECT m.ItemId, i.ItemCode, i.ItemName, m.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId,
           OnHandBase = SUM(m.QuantityBase), LastMovementAtUtc = MAX(m.MovementDate)
    FROM inventory.StockMovements m
    INNER JOIN inventory.Items i ON i.Id = m.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    GROUP BY m.ItemId, i.ItemCode, i.ItemName, m.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId;
GO

/* ================================================================== 4. Stock documents (Inventory In / Out) */

IF OBJECT_ID(N'inventory.StockDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocuments
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId INT            NOT NULL,
        DocumentNumber NVARCHAR(30)   NULL,          -- NULL while a draft of a NumberOnPost type
        DocumentDate   DATE           NOT NULL,
        BranchId       INT            NOT NULL,
        WarehouseId    INT            NOT NULL,      -- default warehouse (lines may differ)
        ReasonId       INT            NULL,
        ReferenceNo    NVARCHAR(100)  NULL,          -- external reference (delivery note, BL, count sheet...)
        CurrencyId     INT            NOT NULL,      -- base currency for stock documents
        ExchangeRate   DECIMAL(18,6)  NOT NULL CONSTRAINT DF_StockDocuments_Rate DEFAULT (1),
        Notes          NVARCHAR(1000) NULL,
        Status         TINYINT        NOT NULL CONSTRAINT DF_StockDocuments_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled
        TotalItems     INT            NOT NULL CONSTRAINT DF_StockDocuments_TotalItems DEFAULT (0),
        TotalQuantity  INT            NOT NULL CONSTRAINT DF_StockDocuments_TotalQuantity DEFAULT (0),   -- base units
        TotalCost      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_StockDocuments_TotalCost DEFAULT (0),
        PostedAtUtc    DATETIME2(3)   NULL,
        PostedBy       INT            NULL,
        CancelledAtUtc DATETIME2(3)   NULL,
        CancelledBy    INT            NULL,
        CancelReason   NVARCHAR(300)  NULL,
        CreatedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_StockDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT            NULL,
        UpdatedAtUtc   DATETIME2(3)   NULL,
        UpdatedBy      INT            NULL,
        RowVersion     ROWVERSION     NOT NULL,
        CONSTRAINT PK_StockDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_StockDocuments_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT FK_StockDocuments_Type      FOREIGN KEY (DocumentTypeId) REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_StockDocuments_Branch    FOREIGN KEY (BranchId)       REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_StockDocuments_Warehouse FOREIGN KEY (WarehouseId)    REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_StockDocuments_Reason    FOREIGN KEY (ReasonId)       REFERENCES inventory.StockReasons (Id),
        CONSTRAINT FK_StockDocuments_Currency  FOREIGN KEY (CurrencyId)     REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_StockDocuments_CreatedBy FOREIGN KEY (CreatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_StockDocuments_UpdatedBy FOREIGN KEY (UpdatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_StockDocuments_PostedBy  FOREIGN KEY (PostedBy)       REFERENCES security.Users (Id),
        CONSTRAINT FK_StockDocuments_CancelledBy FOREIGN KEY (CancelledBy)  REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_StockDocuments_Number ON inventory.StockDocuments (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_StockDocuments_TypeDate   ON inventory.StockDocuments (DocumentTypeId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_StockDocuments_TypeStatus ON inventory.StockDocuments (DocumentTypeId, Status);
    PRINT 'Created inventory.StockDocuments';
END
GO

IF OBJECT_ID(N'inventory.StockDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocumentLines
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        DocumentId     INT           NOT NULL,
        LineNumber         INT           NOT NULL,
        ItemId         INT           NOT NULL,
        ItemUnitId     INT           NOT NULL,
        WarehouseId    INT           NOT NULL,
        ExpiryDate     DATE          NULL,
        Quantity       INT           NOT NULL,          -- in the chosen unit
        PackingFormula INT           NOT NULL,          -- snapshot from the item unit at save time
        QuantityBase   AS (Quantity * PackingFormula) PERSISTED,
        UnitCost       DECIMAL(18,4) NOT NULL CONSTRAINT DF_StockDocumentLines_UnitCost DEFAULT (0),   -- per unit, base currency
        LineTotal      AS (CONVERT(DECIMAL(18,2), Quantity * UnitCost)) PERSISTED,
        Notes          NVARCHAR(300) NULL,
        SourceLineId   INT           NULL,              -- family pattern (conversions) - unused for stock docs
        CONSTRAINT PK_StockDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_StockDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT CK_StockDocumentLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_StockDocumentLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_StockDocumentLines_Cost CHECK (UnitCost >= 0),
        CONSTRAINT FK_StockDocumentLines_Document  FOREIGN KEY (DocumentId)  REFERENCES inventory.StockDocuments (Id),
        CONSTRAINT FK_StockDocumentLines_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_StockDocumentLines_ItemUnit  FOREIGN KEY (ItemUnitId)  REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_StockDocumentLines_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockDocumentLines_Document ON inventory.StockDocumentLines (DocumentId);
    CREATE NONCLUSTERED INDEX IX_StockDocumentLines_Item     ON inventory.StockDocumentLines (ItemId);
    PRINT 'Created inventory.StockDocumentLines';
END
GO

IF OBJECT_ID(N'inventory.StockDocumentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocumentFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        DocumentId   INT            NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_StockDocumentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_StockDocumentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_StockDocumentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_StockDocumentFiles_Document  FOREIGN KEY (DocumentId) REFERENCES inventory.StockDocuments (Id),
        CONSTRAINT FK_StockDocumentFiles_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockDocumentFiles_Document ON inventory.StockDocumentFiles (DocumentId);
    PRINT 'Created inventory.StockDocumentFiles';
END
GO

IF OBJECT_ID(N'inventory.StockDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Posted | Cancelled | Deleted | FileAdded | FileDeleted
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_StockDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_StockDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_StockDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockDocumentAudit_Document ON inventory.StockDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created inventory.StockDocumentAudit';
END
GO

IF TYPE_ID(N'inventory.tvp_StockDocumentLine') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_StockDocumentLine AS TABLE
    (
        LineNumber      INT           NOT NULL PRIMARY KEY,
        ItemId      INT           NOT NULL,
        ItemUnitId  INT           NOT NULL,
        WarehouseId INT           NOT NULL,
        ExpiryDate  DATE          NULL,
        Quantity    INT           NOT NULL,
        UnitCost    DECIMAL(18,4) NULL,       -- NULL = 0 for In; ignored for Out (average cost is used)
        Notes       NVARCHAR(300) NULL
    );
    PRINT 'Created type inventory.tvp_StockDocumentLine';
END
GO

/* ------------------------------------------------------------------ 4a. Search / Get */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,   -- INV_IN | INV_OUT | NULL = both
    @Search           NVARCHAR(100) = NULL,  -- number, reference or notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @Status           TINYINT      = NULL,   -- 1 Draft | 2 Posted | 3 Cancelled
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | BranchName | WarehouseName | Status | TotalCost | CreatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'BranchName', N'WarehouseName', N'Status', N'TotalCost', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.ReasonId, r.ReasonName, d.ReferenceNo, c.CurrencyCode, d.Status,
           d.TotalItems, d.TotalQuantity, d.TotalCost,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.StockDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN inventory.StockReasons r   ON r.Id = d.ReasonId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Inventory'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.ReferenceNo LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'BranchName' THEN b.BranchName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'BranchName' THEN b.BranchName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalCost' THEN d.TotalCost END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalCost' THEN d.TotalCost END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: header, lines, file metadata, audit trail.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchCode, b.BranchName,
           d.WarehouseId, w.WarehouseCode, w.WarehouseName, d.ReasonId, r.ReasonCode, r.ReasonName,
           d.ReferenceNo, d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.TotalCost,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM inventory.StockDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN inventory.StockReasons r   ON r.Id = d.ReasonId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate, l.Quantity, l.QuantityBase,
           l.UnitCost, l.LineTotal, l.Notes, l.SourceLineId,
           OnHandBase = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId)
    FROM inventory.StockDocumentLines l
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM inventory.StockDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.StockDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ------------------------------------------------------------------ 4b. Validation helper (header + lines) */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT;
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 62008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END
GO

/* ------------------------------------------------------------------ 4c. Save (create or update a DRAFT) */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Save
    @Id               INT            = NULL,   -- NULL = create
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT,
    @ReasonId         INT            = NULL,
    @ReferenceNo      NVARCHAR(100)  = NULL,
    @Notes            NVARCHAR(1000) = NULL,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @RowVersion       BINARY(8)      = NULL,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT;
    EXEC inventory.usp_StockDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 62000, 'The document type cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT;

            INSERT INTO inventory.StockDocuments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, WarehouseId, ReasonId,
                                                  ReferenceNo, CurrencyId, ExchangeRate, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @ReferenceNo, @CurrencyId, 1, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.StockDocuments
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, ReasonId = @ReasonId,
                ReferenceNo = @ReferenceNo, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO inventory.StockDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, UnitCost, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               CASE WHEN @Direction = -1 THEN ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * iu.PackingFormula ELSE ISNULL(l.UnitCost, 0) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId;

        UPDATE d SET TotalItems = x.Items, TotalQuantity = x.Qty, TotalCost = x.Cost
        FROM inventory.StockDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty, ISNULL(SUM(LineTotal), 0) AS Cost
                     FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
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

/* ------------------------------------------------------------------ 4d. Post (write the ledger) */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeId INT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @NumberOnPost BIT,
                @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);

        SELECT @Status = d.Status, @TypeId = d.DocumentTypeId, @TypeCode = dt.Code, @Direction = dt.StockDirection,
               @NumberOnPost = dt.NumberOnPost, @Number = d.DocumentNumber, @DocumentDate = d.DocumentDate,
               @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        -- Masters must still be valid at posting time.
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        -- Outgoing documents cannot exceed the stock on hand per item + warehouse.
        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4e. Cancel (reversal) / Delete draft */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 62000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT, @Number NVARCHAR(30), @TypeCode NVARCHAR(20), @BranchId INT, @ReasonCode NVARCHAR(20);
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @Number = d.DocumentNumber, @TypeCode = dt.Code, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 2 THROW 62010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Cancelling an incoming document removes stock again: it must still be there.
        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Inventory' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE inventory.StockDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 62006, 'Document not found.', 1;
    IF @Status <> 1 THROW 62005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM inventory.StockDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4f. Attachments */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @DocumentId) THROW 62006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 62000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 62000, 'The file is empty.', 1;

    INSERT INTO inventory.StockDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM inventory.StockDocumentFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM inventory.StockDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 62006, 'File not found.', 1;
    DELETE FROM inventory.StockDocumentFiles WHERE Id = @Id;
    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 5. Items: real On Hand / costs from the ledger */

CREATE OR ALTER PROCEDURE inventory.usp_Item_Search
    @Search             NVARCHAR(200) = NULL,
    @ItemFamilyId       INT           = NULL,
    @BrandId            INT           = NULL,
    @DefaultWarehouseId INT           = NULL,
    @IsActive           BIT           = NULL,
    @IsBivac            BIT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'ItemCode',
    @SortDirection      NVARCHAR(4)   = N'ASC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BrandName', N'FamilyName', N'WarehouseName', N'IsActive', N'CreatedAtUtc', N'OnHand')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           bu.SkuCode AS BaseUnitSku, ut.UnitTypeName AS BaseUnitName,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           i.CreatedAtUtc, i.CreatedBy, i.UpdatedAtUtc, i.UpdatedBy, i.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b        ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN inventory.ItemUnits bu     ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes ut    ON ut.Id = bu.UnitTypeId
    WHERE (@Search IS NULL
           OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u
                      WHERE u.ItemId = i.Id AND (u.SkuCode LIKE N'%' + @Search + N'%' OR u.Barcode LIKE N'%' + @Search + N'%')))
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@DefaultWarehouseId IS NULL OR i.DefaultWarehouseId = @DefaultWarehouseId)
      AND (@IsActive IS NULL OR i.IsActive = @IsActive)
      AND (@IsBivac IS NULL OR i.IsBivac = @IsBivac)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END DESC,
        i.ItemCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           LastCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                       WHERE m.ItemId = i.Id AND m.QuantityBase > 0 AND m.IsReversal = 0 ORDER BY m.MovementDate DESC, m.Id DESC),
           AverageCost = CAST(inventory.fn_AverageCost(i.Id) AS DECIMAL(18,2)),
           LastPurchaseCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                               WHERE m.ItemId = i.Id AND m.DocumentFamily = N'Purchase' AND m.QuantityBase > 0 AND m.IsReversal = 0
                               ORDER BY m.MovementDate DESC, m.Id DESC),
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 6. Import engine: price list optional (stock documents) */

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = stock document: no pricing, Unit Price column = unit cost (optional)
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the selected branch.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE WHEN @PriceListId IS NULL THEN CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END       -- stock docs: base unit first
                          ELSE CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END END, iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @PriceListId IS NOT NULL AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.' END
        FROM resolved x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ================================================================== 7. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'inventory.stockin.view',     N'View Inventory In',    N'Inventory', N'See Inventory In documents.',                         700),
        (N'inventory.stockin.create',   N'Create Inventory In',  N'Inventory', N'Create and edit draft Inventory In documents.',       710),
        (N'inventory.stockin.post',     N'Post Inventory In',    N'Inventory', N'Post Inventory In documents (adds stock).',           720),
        (N'inventory.stockin.cancel',   N'Cancel Inventory In',  N'Inventory', N'Cancel posted Inventory In documents (reversal).',    730),
        (N'inventory.stockin.delete',   N'Delete Inventory In',  N'Inventory', N'Delete draft Inventory In documents.',                740),
        (N'inventory.stockout.view',    N'View Inventory Out',   N'Inventory', N'See Inventory Out documents.',                        760),
        (N'inventory.stockout.create',  N'Create Inventory Out', N'Inventory', N'Create and edit draft Inventory Out documents.',      770),
        (N'inventory.stockout.post',    N'Post Inventory Out',   N'Inventory', N'Post Inventory Out documents (removes stock).',       780),
        (N'inventory.stockout.cancel',  N'Cancel Inventory Out', N'Inventory', N'Cancel posted Inventory Out documents (reversal).',   790),
        (N'inventory.stockout.delete',  N'Delete Inventory Out', N'Inventory', N'Delete draft Inventory Out documents.',               800),
        (N'inventory.documenttypes.manage', N'Manage document types', N'Configuration', N'Change numbering and behaviour of document types.', 900)
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
WHERE (p.Code LIKE N'inventory.stockin.%' OR p.Code LIKE N'inventory.stockout.%' OR p.Code = N'inventory.documenttypes.manage')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'inventory.stockin.view', N'inventory.stockout.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 8. Report */

SELECT Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberOnPost, RequiresReason FROM inventory.DocumentTypes ORDER BY Family, Code;
SELECT ReasonCode, ReasonName, AppliesTo FROM inventory.StockReasons ORDER BY AppliesTo, ReasonName;
SELECT p.Code, p.Module FROM security.Permissions p WHERE p.Code LIKE N'inventory.stock%' OR p.Code LIKE N'inventory.documenttypes.%' ORDER BY p.SortOrder;
PRINT 'Inventory In / Out documents + Stock Movements ledger are ready.';
GO
