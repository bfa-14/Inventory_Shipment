/* ================================================================== 7. The stock level procedures */

/* (91) INVENTORY > STOCK LEVELS, "Per warehouse" (and the item card, with @ItemId, activeItemsOnly 0, inactive
   warehouses too): every level of the scope with where its warehouse stands, or (@Status NoLevel) the item /
   warehouse pairs of the scope WITHOUT a level that hold stock (a ledger balance other than 0) or appear on a released
   transfer order (as To with goods on the way or to dispatch, as From with goods to dispatch). Scope: warehouses at
   the bottom of the tree, never On the way, active unless @IncludeInactiveWarehouses; @WarehouseId = that warehouse or
   the leaves under it; @ItemFamilyId = the family and its sub-families; @Search = item code or name (LIKE) or a unit's
   barcode (exactly). Result 1: the rows, Below Min first, then Below Min covered, Above Max, OK (then the pairs without
   a level), item code, warehouse code. Result 2: the scope's totals, levels only, whatever @Status. */
CREATE   PROCEDURE inventory.usp_StockLevel_Search
    @Search                    NVARCHAR(100) = NULL,
    @BranchId                  INT           = NULL,
    @WarehouseId               INT           = NULL,
    @ItemFamilyId              INT           = NULL,
    @BrandId                   INT           = NULL,
    @ItemId                    INT           = NULL,
    @Status                    NVARCHAR(20)  = NULL,
    @ActiveItemsOnly           BIT           = 1,
    @IncludeInactiveWarehouses BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    SET @ActiveItemsOnly = ISNULL(@ActiveItemsOnly, 1);
    SET @IncludeInactiveWarehouses = ISNULL(@IncludeInactiveWarehouses, 0);

    IF @Status IS NOT NULL AND @Status NOT IN (N'BelowMin', N'Covered', N'AboveMax', N'Ok', N'NoLevel')
        THROW 56000, 'Unknown status: choose Below Min, Below Min covered, Above Max, OK or Without a level.', 1;

    -- The warehouses of the scope
    CREATE TABLE #wh (Id INT NOT NULL PRIMARY KEY);
    DECLARE @Under TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Under (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;

    INSERT INTO #wh (Id)
    SELECT w.Id
    FROM masterdata.Warehouses w
    WHERE w.IsTransit = 0
      AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
      AND (w.IsActive = 1 OR @IncludeInactiveWarehouses = 1)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR w.Id IN (SELECT u.Id FROM @Under u));

    -- The items of the scope
    CREATE TABLE #it (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO #it (Id)
    SELECT i.Id
    FROM inventory.Items i
    WHERE (@ActiveItemsOnly = 0 OR i.IsActive = 1)
      AND (@ItemId IS NULL OR i.Id = @ItemId)
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.Barcode = @Search));

    -- The pairs of the scope: every level, and (Without a level) the pairs without one that hold stock (a ledger balance
    -- other than 0) or appear on a released transfer order (as To with goods on the way or to dispatch, as From with
    -- goods to dispatch)
    CREATE TABLE #pr (ItemId INT NOT NULL, WarehouseId INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #pr (ItemId, WarehouseId)
    SELECT lv.ItemId, lv.WarehouseId
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN #wh w ON w.Id = lv.WarehouseId
    INNER JOIN #it i ON i.Id = lv.ItemId;

    -- What released transfer orders bring to and take from the scope's warehouses, every pair at once
    -- (fn_TransferPositions: fn_TransferPosition's sums, set-based - read once per pair they cost the item's whole
    -- transfer history each time)
    CREATE TABLE #tp
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL,
        OutToDispatchBase INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId)
    );
    INSERT INTO #tp (ItemId, WarehouseId, InOnTheWayBase, InToDispatchBase, OutToDispatchBase)
    SELECT tp.ItemId, tp.WarehouseId, tp.InOnTheWayBase, tp.InToDispatchBase, tp.OutToDispatchBase
    FROM inventory.fn_TransferPositions(NULL) tp
    INNER JOIN #wh w ON w.Id = tp.WarehouseId
    INNER JOIN #it i ON i.Id = tp.ItemId;

    IF @Status = N'NoLevel'
        INSERT INTO #pr (ItemId, WarehouseId)
        SELECT x.ItemId, x.WarehouseId
        FROM
        (
            SELECT m.ItemId, m.WarehouseId
            FROM inventory.StockMovements m
            INNER JOIN #wh w ON w.Id = m.WarehouseId
            INNER JOIN #it i ON i.Id = m.ItemId
            GROUP BY m.ItemId, m.WarehouseId
            HAVING SUM(m.QuantityBase) <> 0
            UNION
            SELECT tp.ItemId, tp.WarehouseId
            FROM #tp tp
            WHERE tp.InOnTheWayBase + tp.InToDispatchBase > 0 OR tp.OutToDispatchBase > 0
        ) x
        WHERE NOT EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels lv WHERE lv.ItemId = x.ItemId AND lv.WarehouseId = x.WarehouseId);

    -- Where each pair stands, worked out once for every pair: the ledger's on hand, what released transfer orders bring
    -- and take (#tp), the level, and fn_StockLevelState's Projected and status (M6: the formula of fn_StockPosition)
    CREATE TABLE #pos
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, HasLevel BIT NOT NULL, MinQuantityBase INT NULL, MaxQuantityBase INT NULL,
        OnHandBase INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL, OutToDispatchBase INT NOT NULL,
        ProjectedBase INT NOT NULL, ToReachMaxBase INT NOT NULL, Status NVARCHAR(10) NOT NULL,
        PRIMARY KEY (ItemId, WarehouseId)
    );

    INSERT INTO #pos (ItemId, WarehouseId, HasLevel, MinQuantityBase, MaxQuantityBase, OnHandBase, InOnTheWayBase,
                      InToDispatchBase, OutToDispatchBase, ProjectedBase, ToReachMaxBase, Status)
    SELECT pr.ItemId, pr.WarehouseId, CAST(CASE WHEN lv.ItemId IS NULL THEN 0 ELSE 1 END AS BIT), lv.MinQuantityBase, lv.MaxQuantityBase,
           q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase, st.ProjectedBase, st.ToReachMaxBase, st.Status
    FROM #pr pr
    LEFT JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = pr.ItemId AND lv.WarehouseId = pr.WarehouseId
    LEFT JOIN #tp tp ON tp.ItemId = pr.ItemId AND tp.WarehouseId = pr.WarehouseId
    LEFT JOIN (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
               FROM inventory.StockMovements m
               INNER JOIN #pr x ON x.ItemId = m.ItemId AND x.WarehouseId = m.WarehouseId
               GROUP BY m.ItemId, m.WarehouseId) oh ON oh.ItemId = pr.ItemId AND oh.WarehouseId = pr.WarehouseId
    CROSS APPLY (SELECT OnHandBase = ISNULL(oh.Qty, 0), InOnTheWayBase = ISNULL(tp.InOnTheWayBase, 0),
                        InToDispatchBase = ISNULL(tp.InToDispatchBase, 0), OutToDispatchBase = ISNULL(tp.OutToDispatchBase, 0)) q
    CROSS APPLY inventory.fn_StockLevelState(q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase,
                                             lv.MinQuantityBase, lv.MaxQuantityBase) st;

    -- 1: the rows
    SELECT p.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive, ItemFamilyName = f.FamilyName, b.BrandName,
           p.WarehouseId, w.WarehouseCode, w.WarehouseName, WarehouseIsActive = w.IsActive,
           w.BranchId, br.BranchCode, br.BranchName,
           p.HasLevel, p.MinQuantityBase, p.MaxQuantityBase,
           p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase, p.ProjectedBase, p.ToReachMaxBase, p.Status,
           lv.UpdatedAtUtc, UpdatedByName = u.FullName, RowVersion = CAST(lv.RowVersion AS BINARY(8))
    FROM #pos p
    INNER JOIN inventory.Items i            ON i.Id = p.ItemId
    INNER JOIN masterdata.Warehouses w      ON w.Id = p.WarehouseId
    INNER JOIN masterdata.Branches br       ON br.Id = w.BranchId
    LEFT  JOIN masterdata.ItemFamilies f    ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b          ON b.Id = i.BrandId
    LEFT  JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = p.ItemId AND lv.WarehouseId = p.WarehouseId
    LEFT  JOIN security.Users u             ON u.Id = lv.UpdatedBy
    WHERE @Status IS NULL OR p.Status = @Status
    ORDER BY CASE p.Status WHEN N'BelowMin' THEN 1 WHEN N'Covered' THEN 2 WHEN N'AboveMax' THEN 3 WHEN N'Ok' THEN 4 ELSE 5 END,
             i.ItemCode, w.WarehouseCode;

    -- 2: the scope's totals (levels only, the status filter ignored)
    SELECT Levels   = COUNT(*),
           BelowMin = ISNULL(SUM(CASE WHEN p.Status = N'BelowMin' THEN 1 ELSE 0 END), 0),
           Covered  = ISNULL(SUM(CASE WHEN p.Status = N'Covered'  THEN 1 ELSE 0 END), 0),
           AboveMax = ISNULL(SUM(CASE WHEN p.Status = N'AboveMax' THEN 1 ELSE 0 END), 0),
           Ok       = ISNULL(SUM(CASE WHEN p.Status = N'Ok'       THEN 1 ELSE 0 END), 0)
    FROM #pos p
    WHERE p.HasLevel = 1;
END

GO

