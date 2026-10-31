/* ================================================================== 9. Dashboard: warehouse levels below Min (L3) */

-- (91) THE DASHBOARD'S "WAREHOUSE LEVELS BELOW MIN": the levels of active items at active warehouses (of the branch, or
--      of the company) whose Projected stock is below their Min - the Stock Levels page's "Below Min" tile for the same
--      branch with its default filters (test g), worked out the same set-based way. Read by the API after the summary
--      and the charts, only for a reader who may see it (View Items and View Stock Levels); the summary procedure is not
--      touched.
CREATE   PROCEDURE reporting.usp_Dashboard_StockLevels
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- The levels counted: active items at active warehouses of the branch (or the company)
    CREATE TABLE #lv (ItemId INT NOT NULL, WarehouseId INT NOT NULL, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL,
                      PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #lv (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
    SELECT lv.ItemId, lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN inventory.Items i       ON i.Id = lv.ItemId AND i.IsActive = 1
    INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId AND w.IsActive = 1
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId;

    -- What released transfer orders bring and take, every pair at once (fn_TransferPositions, as Stock Levels reads it)
    CREATE TABLE #tp (ItemId INT NOT NULL, WarehouseId INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL,
                      OutToDispatchBase INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #tp (ItemId, WarehouseId, InOnTheWayBase, InToDispatchBase, OutToDispatchBase)
    SELECT tp.ItemId, tp.WarehouseId, tp.InOnTheWayBase, tp.InToDispatchBase, tp.OutToDispatchBase
    FROM inventory.fn_TransferPositions(NULL) tp
    WHERE EXISTS (SELECT 1 FROM #lv lv WHERE lv.ItemId = tp.ItemId AND lv.WarehouseId = tp.WarehouseId);

    SELECT BelowWarehouseMin = COUNT(*)
    FROM #lv lv
    LEFT JOIN #tp tp ON tp.ItemId = lv.ItemId AND tp.WarehouseId = lv.WarehouseId
    LEFT JOIN (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
               FROM inventory.StockMovements m
               INNER JOIN #lv x ON x.ItemId = m.ItemId AND x.WarehouseId = m.WarehouseId
               GROUP BY m.ItemId, m.WarehouseId) oh ON oh.ItemId = lv.ItemId AND oh.WarehouseId = lv.WarehouseId
    CROSS APPLY inventory.fn_StockLevelState(ISNULL(oh.Qty, 0), ISNULL(tp.InOnTheWayBase, 0), ISNULL(tp.InToDispatchBase, 0),
                                             ISNULL(tp.OutToDispatchBase, 0), lv.MinQuantityBase, lv.MaxQuantityBase) st
    WHERE st.Status = N'BelowMin';
END

GO

