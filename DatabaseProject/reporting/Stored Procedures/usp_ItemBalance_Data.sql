-- Re-created (114) from the body of script 103: COLLATE DATABASE_DEFAULT on the text columns of its #tables (3).
CREATE   PROCEDURE reporting.usp_ItemBalance_Data
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
    CREATE TABLE #Undone (DocumentFamily NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, DocumentTypeCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, DocumentId INT NOT NULL,
                          DocumentNumber NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL);
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