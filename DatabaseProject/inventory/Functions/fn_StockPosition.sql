--      and the level, the status of fn_StockLevelState). The readers of many pairs use fn_TransferPositions with the
--      same fn_StockLevelState; Check 6 proves the two agree (M6: one formula).
CREATE   FUNCTION inventory.fn_StockPosition (@ItemId INT, @WarehouseId INT, @ExcludeOrderId INT)
RETURNS TABLE
AS
RETURN
(
    -- (91) WHERE A WAREHOUSE STANDS FOR AN ITEM, WITH ITS LEVEL: script 90's position (on hand, what released transfer
    --      orders bring and take, Projected) and the warehouse's Min / Max. Purchases are not counted (L11).
    SELECT p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase, p.ProjectedBase,
           HasLevel       = CAST(CASE WHEN lv.MinQuantityBase IS NULL THEN 0 ELSE 1 END AS BIT),
           MinBase        = lv.MinQuantityBase,
           MaxBase        = lv.MaxQuantityBase,
           st.Status,
           st.ToReachMaxBase
    FROM inventory.fn_TransferPosition(@ItemId, @WarehouseId, @ExcludeOrderId) p
    OUTER APPLY (SELECT v.MinQuantityBase, v.MaxQuantityBase FROM inventory.ItemWarehouseLevels v
                 WHERE v.ItemId = @ItemId AND v.WarehouseId = @WarehouseId) lv
    CROSS APPLY inventory.fn_StockLevelState(p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase,
                                             lv.MinQuantityBase, lv.MaxQuantityBase) st
);

GO

