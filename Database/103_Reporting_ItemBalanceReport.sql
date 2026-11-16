SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 103: REPORTING - THE ITEM BALANCE REPORT BY WAREHOUSE

   Reports › Item Balance Report: for each item in each warehouse, the opening balance on Date From, one quantity and
   amount per kind of movement in the period (purchase receipts, sales, transfers, Inventory In / Out, BIVAC Out, ...),
   the cost adjustments, the change of the average cost and the closing balance on Date To, in the base currency or
   translated into another one. For month-end: the stock checked against Stock Valuation and the books.

   THE SYSTEM'S OWN COST (the owner's choice): one weighted average per item for the whole company, replayed from the
   ledger as inventory.usp_Item_RebuildCosts replays it - a receipt at its own cost, everything that leaves (and both
   legs of a transfer) at the average in effect, a cost adjustment (landed cost adjustment, a late container charge, an
   invoice's true-up) spread over the stock then on hand, the average kept while the stock is at or below zero and set
   by the first receipt that brings it back above. The opening and the closing are each warehouse's quantity at the
   average of that day, so the closing amounts of every warehouse add up to Stock Valuation; what the average did in
   between (receipts into other warehouses, cost adjustments) is the row's "Average cost change", so each row adds up.

   NOTHING IS STORED: every run reads the ledger from its first row (no period-end snapshot). This script only gives
   the API the rows; the replay, the groups, the currency and the totals are the API's (ItemBalanceReportService).

     1. THE PERMISSION reports.itembalance.view "View Item Balance Report" (module Reports, 1510). Not granted to any
        role here: the start-up sync gives it to the system roles, the others get it in Role Permissions. The amounts
        also need View item costs (inventory.costs.view, script 94): without it the report shows quantities only.
     2. reporting.ItemBalanceReportRuns: one row per run (who, when, the filters, how many rows, how long, screen,
        Excel or print).
     3. reporting.usp_ItemBalance_Warehouses: the warehouses the filter offers the user - every one for a user with All
        warehouses (the On the way warehouses of transfers too), else only theirs (script 92: a ticked warehouse and
        every warehouse under it; never an On the way warehouse). Unlike the other reports, which show every warehouse
        to everyone, this one follows the user's warehouses: the owner's story asks for it.
     4. reporting.usp_ItemBalance_Data: for the warehouses, items and families chosen, up to Date To:
          1) the items (code, name, base unit, family)
          2) the warehouses (code, name, and the warehouse at the top of its tree: a warehouse under another one is a
             location of it, shown as its own row, never rolled up)
          3) the events of the items, oldest first, in every warehouse (the average is the company's): each stock
             movement and each cost adjustment, the movements of cancelled or reversed documents left out (both the
             posting and its reversal, as usp_Item_RebuildCosts leaves them out), with its group (the document type
             and its direction; the receipts of before goods receipts - a container offload, a local invoice - are
             purchase receipts, GRN+) and, with @Detail = 1, its document
          4) the ledger's quantity on Date To per item and warehouse, every row counted: the integrity check (the
             opening and the movements must give it)
        A warehouse the user may not use is refused (50010, "You have no access to warehouse LKS-01: ask an
        administrator."); none chosen = every warehouse the user may use.
     5. reporting.usp_ItemBalance_Rates: the rates of a currency and rate type up to Date To.
     6. reporting.usp_ItemBalance_LogRun.

   Requires scripts 89 (the cost adjustments' warehouse), 90 (transfers), 92 (warehouse access) and 101 (the reporting
   schema). Idempotent, additive. No new error number.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.TransferPostings', N'U') IS NULL
   OR OBJECT_ID(N'security.fn_User_WarehouseRefusal', N'FN') IS NULL
   OR SCHEMA_ID(N'reporting') IS NULL
    THROW 50000, 'Script 103 requires scripts 90, 92 and 101: apply them first.', 1;
GO

/* ================================================================== 1. reports.itembalance.view */

-- The texts are PermissionCatalog.cs's, so the start-up sync changes nothing.
MERGE security.Permissions AS target
USING (VALUES (N'reports.itembalance.view', N'View Item Balance Report', N'Reports',
               N'Reports › Item Balance Report: opening, movements and closing of each item per warehouse over a period; the amounts also need View item costs.',
               1510)) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                  OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

/* ================================================================== 2. The run log */

IF OBJECT_ID(N'reporting.ItemBalanceReportRuns', N'U') IS NULL
    CREATE TABLE reporting.ItemBalanceReportRuns
    (
        Id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ItemBalanceReportRuns PRIMARY KEY,
        UserId      INT            NOT NULL,
        RunAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_ItemBalanceReportRuns_At DEFAULT SYSUTCDATETIME(),
        OutputKind  NVARCHAR(10)   NOT NULL,   -- Screen | Excel | Print
        DateFrom    DATE           NOT NULL,
        DateTo      DATE           NOT NULL,
        CurrencyId  INT            NULL,       -- NULL: quantities only (no View item costs)
        RateType    TINYINT        NULL,
        Criteria    NVARCHAR(MAX)  NULL,       -- every filter, as JSON
        RowsReturned INT           NOT NULL,
        DurationMs  INT            NOT NULL,
        CONSTRAINT FK_ItemBalanceReportRuns_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
GO

/* ================================================================== 3. reporting.usp_ItemBalance_Warehouses */

-- The warehouses the filter offers, as a tree (ParentId, Level). A user with All warehouses (or a system role) gets
-- every one, the On the way warehouses of transfers too; a restricted user only theirs. Inactive warehouses are offered
-- (they may hold history).
CREATE OR ALTER PROCEDURE reporting.usp_ItemBalance_Warehouses
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF security.fn_User_IsUnrestricted(@UserId) = 1
        INSERT INTO @Usable (WarehouseId) SELECT Id FROM masterdata.Warehouses;
    ELSE
        INSERT INTO @Usable (WarehouseId)
        SELECT u.WarehouseId
        FROM security.fn_User_Warehouses(@UserId) u
        INNER JOIN masterdata.Warehouses w ON w.Id = u.WarehouseId
        WHERE w.IsTransit = 0;

    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.ParentId, w.Level, w.IsTransit, w.IsActive,
           b.BranchCode,
           HasChildren = CAST(CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id) THEN 1 ELSE 0 END AS BIT)
    FROM @Usable u
    INNER JOIN masterdata.Warehouses w ON w.Id = u.WarehouseId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    ORDER BY w.IsTransit, b.BranchCode, w.WarehouseCode;
END
GO

/* ================================================================== 4. reporting.usp_ItemBalance_Data */

CREATE OR ALTER PROCEDURE reporting.usp_ItemBalance_Data
    @UserId       INT,
    @WarehouseIds NVARCHAR(MAX) = NULL,    -- comma separated; a parent takes every warehouse under it; NULL / empty = all the user's
    @ItemIds      NVARCHAR(MAX) = NULL,    -- comma separated
    @FamilyIds    NVARCHAR(MAX) = NULL,    -- comma separated; a family takes its sub-families. Items and families: either
    @DateFrom     DATE,
    @DateTo       DATE,
    @Detail       BIT = 0                  -- 1: the events carry their document (the drill-down)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start DATETIME2(3) = CAST(@DateFrom AS DATETIME2(3));
    DECLARE @End   DATETIME2(3) = DATEADD(DAY, 1, CAST(@DateTo AS DATETIME2(3)));   -- Date To inclusive

    /* -- The warehouses: the user's, the chosen ones (and everything under them) among them ------------------------ */
    DECLARE @Refusal NVARCHAR(400) = security.fn_User_WarehouseRefusal(@UserId, NULLIF(LTRIM(RTRIM(@WarehouseIds)), N''));
    IF @Refusal IS NOT NULL THROW 50010, @Refusal, 1;

    CREATE TABLE #Usable (WarehouseId INT NOT NULL PRIMARY KEY);
    IF security.fn_User_IsUnrestricted(@UserId) = 1
        INSERT INTO #Usable (WarehouseId) SELECT Id FROM masterdata.Warehouses;
    ELSE
        INSERT INTO #Usable (WarehouseId)
        SELECT u.WarehouseId FROM security.fn_User_Warehouses(@UserId) u
        INNER JOIN masterdata.Warehouses w ON w.Id = u.WarehouseId
        WHERE w.IsTransit = 0;

    CREATE TABLE #Wh (WarehouseId INT NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@WarehouseIds)), N'') IS NULL
        INSERT INTO #Wh (WarehouseId) SELECT WarehouseId FROM #Usable;
    ELSE
        INSERT INTO #Wh (WarehouseId)
        SELECT DISTINCT s.Id
        FROM (SELECT DISTINCT Id = TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@WarehouseIds, N',')) p
        CROSS APPLY masterdata.fn_Warehouse_Subtree(p.Id) s
        INNER JOIN #Usable u ON u.WarehouseId = s.Id
        WHERE p.Id IS NOT NULL;

    /* -- The items: the chosen ones and those of the chosen families (and their sub-families); none = every item --- */
    DECLARE @AllItems BIT = CASE WHEN NULLIF(LTRIM(RTRIM(@ItemIds)), N'') IS NULL AND NULLIF(LTRIM(RTRIM(@FamilyIds)), N'') IS NULL THEN 1 ELSE 0 END;
    CREATE TABLE #Chosen (ItemId INT NOT NULL PRIMARY KEY);
    IF @AllItems = 0
    BEGIN
        WITH fam AS
        (
            SELECT f.Id FROM masterdata.ItemFamilies f
            WHERE f.Id IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(ISNULL(@FamilyIds, N''), N','))
            UNION ALL
            SELECT c.Id FROM masterdata.ItemFamilies c INNER JOIN fam ON c.ParentId = fam.Id
        )
        INSERT INTO #Chosen (ItemId)
        SELECT i.Id FROM inventory.Items i
        WHERE i.Id IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(ISNULL(@ItemIds, N''), N','))
           OR i.ItemFamilyId IN (SELECT Id FROM fam);
    END

    /* -- The documents left out: cancelled or reversed (their posting and its reversal), as usp_Item_RebuildCosts -- */
    CREATE TABLE #Undone (DocumentFamily NVARCHAR(20) NOT NULL, DocumentTypeCode NVARCHAR(20) NOT NULL, DocumentId INT NOT NULL,
                          DocumentNumber NVARCHAR(30) NOT NULL);
    INSERT INTO #Undone (DocumentFamily, DocumentTypeCode, DocumentId, DocumentNumber)
    SELECT DISTINCT r.DocumentFamily, r.DocumentTypeCode, r.DocumentId, r.DocumentNumber
    FROM inventory.StockMovements r
    WHERE r.IsReversal = 1 AND r.MovementDate < @End;
    CREATE INDEX IX_Undone ON #Undone (DocumentFamily, DocumentTypeCode, DocumentId);

    /* -- The items of the report: a movement (or a cost adjustment) in one of the warehouses before Date To ends --- */
    CREATE TABLE #Scope (ItemId INT NOT NULL PRIMARY KEY);
    INSERT INTO #Scope (ItemId)
    SELECT DISTINCT m.ItemId
    FROM inventory.StockMovements m
    INNER JOIN #Wh w ON w.WarehouseId = m.WarehouseId
    WHERE m.MovementDate < @End
      AND (@AllItems = 1 OR EXISTS (SELECT 1 FROM #Chosen c WHERE c.ItemId = m.ItemId));
    INSERT INTO #Scope (ItemId)
    SELECT DISTINCT a.ItemId
    FROM inventory.CostAdjustments a
    INNER JOIN #Wh w ON w.WarehouseId = a.WarehouseId
    WHERE a.Kind = N'Inventory' AND a.AdjustmentDate < @End
      AND (@AllItems = 1 OR EXISTS (SELECT 1 FROM #Chosen c WHERE c.ItemId = a.ItemId))
      AND NOT EXISTS (SELECT 1 FROM #Scope s WHERE s.ItemId = a.ItemId);

    /* -- 1) the items --------------------------------------------------------------------------------------------- */
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName,
           Unit = (SELECT TOP (1) ut.UnitTypeName FROM inventory.ItemUnits u
                   INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
                   WHERE u.ItemId = i.Id AND u.IsBaseUnit = 1 ORDER BY u.Id),
           f.FamilyName
    FROM #Scope s
    INNER JOIN inventory.Items i            ON i.Id = s.ItemId
    LEFT  JOIN masterdata.ItemFamilies f    ON f.Id = i.ItemFamilyId;

    /* -- 2) the warehouses, each with the warehouse at the top of its tree ---------------------------------------- */
    WITH up AS
    (
        SELECT w.WarehouseId, AncestorId = w.WarehouseId, Depth = 0
        FROM #Wh w
        UNION ALL
        SELECT up.WarehouseId, p.ParentId, up.Depth + 1
        FROM up
        INNER JOIN masterdata.Warehouses p ON p.Id = up.AncestorId
        WHERE p.ParentId IS NOT NULL AND up.Depth < 20
    ),
    root AS
    (
        SELECT WarehouseId, AncestorId, Rn = ROW_NUMBER() OVER (PARTITION BY WarehouseId ORDER BY Depth DESC) FROM up
    )
    SELECT w.Id AS WarehouseId, w.WarehouseCode, w.WarehouseName, w.IsTransit, b.BranchCode,
           RootId = r.Id, RootCode = r.WarehouseCode, RootName = r.WarehouseName
    FROM root x
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    INNER JOIN masterdata.Warehouses r ON r.Id = x.AncestorId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    WHERE x.Rn = 1;

    /* -- 3) the events, in the replay's order (usp_Item_RebuildCosts: the date, movements before adjustments, id) -- */
    SELECT e.ItemId, e.WarehouseId, e.EventDate, e.Qty, e.Cost, e.Amount, e.GroupCode,
           InScope  = CAST(CASE WHEN EXISTS (SELECT 1 FROM #Wh w WHERE w.WarehouseId = e.WarehouseId) THEN 1 ELSE 0 END AS BIT),
           InPeriod = CAST(CASE WHEN e.EventAt >= @Start THEN 1 ELSE 0 END AS BIT),
           -- the drill-down only
           EventAt          = CASE WHEN @Detail = 1 THEN e.EventAt END,
           DocumentTypeCode = CASE WHEN @Detail = 1 THEN e.DocumentTypeCode END,
           DocumentId       = CASE WHEN @Detail = 1 THEN e.DocumentId END,
           DocumentNumber   = CASE WHEN @Detail = 1 THEN e.DocumentNumber END,
           TransferOrderId  = CASE WHEN @Detail = 1 AND e.DocumentFamily = N'Transfer'
                                   THEN (SELECT tp.TransferOrderId FROM inventory.TransferPostings tp WHERE tp.Id = e.DocumentId) END
    FROM
    (
        SELECT m.ItemId, m.WarehouseId, EventAt = m.MovementDate, EventDate = CAST(m.MovementDate AS DATE), Src = 1, SrcId = m.Id,
               Qty = m.QuantityBase,
               -- (90) A TRANSFER MOVES NO COST: its incoming legs enter at the running average (NULL here).
               Cost = CASE WHEN m.DocumentFamily = N'Transfer' AND m.QuantityBase > 0 THEN NULL ELSE m.UnitCostBase END,
               Amount = CAST(NULL AS DECIMAL(18,2)),
               -- A container offload (CNT) or a local invoice (PINV) received goods before goods receipts: a purchase receipt.
               GroupCode = CASE WHEN m.DocumentTypeCode IN (N'CNT', N'PINV') AND m.QuantityBase > 0 THEN N'GRN+'
                                WHEN m.ReasonCode = N'TRF_LOSS' THEN N'TRF_LOSS'
                                WHEN m.DocumentFamily = N'Transfer' THEN CASE WHEN m.QuantityBase > 0 THEN N'TRF+' ELSE N'TRF-' END
                                ELSE m.DocumentTypeCode + CASE WHEN m.QuantityBase > 0 THEN N'+' ELSE N'-' END END,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentNumber
        FROM inventory.StockMovements m
        INNER JOIN #Scope s ON s.ItemId = m.ItemId
        WHERE m.MovementDate < @End
          AND NOT EXISTS (SELECT 1 FROM #Undone r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                                    AND r.DocumentId = m.DocumentId
                                                    AND (m.DocumentTypeCode <> N'CNT' OR r.DocumentNumber = m.DocumentNumber))
        UNION ALL
        SELECT a.ItemId, a.WarehouseId, a.AdjustmentDate, CAST(a.AdjustmentDate AS DATE), 2, CAST(a.Id AS INT), 0, NULL, a.AmountBase,
               N'ADJ', N'CostAdjustment', a.SourceKind, a.SourceId, a.SourceNumber
        FROM inventory.CostAdjustments a
        INNER JOIN #Scope s ON s.ItemId = a.ItemId
        WHERE a.Kind = N'Inventory' AND a.AdjustmentDate < @End
    ) e
    ORDER BY e.ItemId, e.EventAt, e.Src, e.SrcId;

    /* -- 4) the ledger's quantity on Date To, every row counted (the integrity check) ----------------------------- */
    SELECT m.ItemId, m.WarehouseId, QuantityBase = SUM(CAST(m.QuantityBase AS BIGINT))
    FROM inventory.StockMovements m
    INNER JOIN #Scope s ON s.ItemId = m.ItemId
    INNER JOIN #Wh w    ON w.WarehouseId = m.WarehouseId
    WHERE m.MovementDate < @End
    GROUP BY m.ItemId, m.WarehouseId;
END
GO

/* ================================================================== 5. reporting.usp_ItemBalance_Rates */

-- The currency and the rates of its rate type up to Date To (1 base currency = Rate x the currency), oldest first.
CREATE OR ALTER PROCEDURE reporting.usp_ItemBalance_Rates
    @CurrencyId INT,
    @RateType   TINYINT,
    @DateTo     DATE
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, CurrencyCode, CurrencyName, DecimalPlaces, IsBaseCurrency
    FROM masterdata.Currencies
    WHERE Id = @CurrencyId;

    SELECT RateDate, Rate
    FROM masterdata.ExchangeRates
    WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate <= @DateTo
    ORDER BY RateDate;
END
GO

/* ================================================================== 6. reporting.usp_ItemBalance_LogRun */

CREATE OR ALTER PROCEDURE reporting.usp_ItemBalance_LogRun
    @UserId     INT,
    @OutputKind NVARCHAR(10),
    @DateFrom   DATE,
    @DateTo     DATE,
    @CurrencyId INT = NULL,
    @RateType   TINYINT = NULL,
    @Criteria   NVARCHAR(MAX) = NULL,
    @RowsReturned INT,
    @DurationMs INT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO reporting.ItemBalanceReportRuns (UserId, OutputKind, DateFrom, DateTo, CurrencyId, RateType, Criteria, RowsReturned, DurationMs)
    VALUES (@UserId, @OutputKind, @DateFrom, @DateTo, @CurrencyId, @RateType, @Criteria, @RowsReturned, @DurationMs);
END
GO

/* ================================================================== 7. Check */

SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE Code = N'reports.itembalance.view';

PRINT 'Script 103 applied: the Item Balance Report (reports.itembalance.view, reporting.usp_ItemBalance_*).';
GO
