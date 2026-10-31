/* (91) THE IMPORT'S WHOLE JUDGEMENT (3.4.5, S12), one row per file row, read by usp_ItemWarehouseLevel_ImportCheck AND
   usp_ItemWarehouseLevel_Import, so the check and the import never disagree. The item: its code equal to the trimmed
   text, else a unit whose barcode equals it (the code first). The warehouse: its code, else its name; a name that
   several warehouses have (and no code) is an error (L20). Status, Action and Message, the first that applies:
     1 an unreadable cell (the API's sentence)                                         Error
     2 item / warehouse missing or unknown, an ambiguous name, an On the way warehouse, a parent, the same item and
       warehouse on several rows (every such row; up to 20 row numbers, then "and n more")       Error
     3 Remove = Yes: no level -> Unchanged; Min or Max typed -> Warning (Remove); else Valid (Remove)
     4 Min and Max empty -> Unchanged; Min empty with a Max -> Error; Min below 0 -> Error; Min or Max above
       1,000,000,000 pcs -> Error; Max < Min -> Error
     5 equal to the level stored -> Unchanged     6 an inactive warehouse -> Error
     7 an inactive item -> Warning (Set)            8 else Valid (Set)
   Every Error and Unchanged row has Action None. */
CREATE   FUNCTION inventory.fn_ItemWarehouseLevel_ImportJudge (@Rows inventory.tvp_ItemWarehouseLevelImport READONLY)
RETURNS TABLE
AS
RETURN
(
    WITH r AS
    (
        SELECT x.RowNumber, x.ParseError, x.IsRemove, x.MinQuantityBase, x.MaxQuantityBase,
               ItemInput      = NULLIF(LTRIM(RTRIM(x.ItemRef)), N''),
               WarehouseInput = NULLIF(LTRIM(RTRIM(x.WarehouseRef)), N'')
        FROM @Rows x
    ),
    res AS
    (
        SELECT r.RowNumber, r.ParseError, r.IsRemove, r.MinQuantityBase, r.MaxQuantityBase, r.ItemInput, r.WarehouseInput,
               ItemId      = COALESCE(ic.Id, ib.ItemId),
               WarehouseId = COALESCE(wc.Id, CASE WHEN wn.N = 1 THEN wn.Id END),
               NameMatches = ISNULL(wn.N, 0)
        FROM r
        OUTER APPLY (SELECT TOP (1) i.Id FROM inventory.Items i
                     WHERE r.ItemInput IS NOT NULL AND i.ItemCode = r.ItemInput) ic
        OUTER APPLY (SELECT TOP (1) u.ItemId FROM inventory.ItemUnits u
                     WHERE ic.Id IS NULL AND r.ItemInput IS NOT NULL AND u.Barcode = r.ItemInput
                     ORDER BY u.Id) ib
        OUTER APPLY (SELECT TOP (1) w.Id FROM masterdata.Warehouses w
                     WHERE r.WarehouseInput IS NOT NULL AND w.WarehouseCode = r.WarehouseInput) wc
        OUTER APPLY (SELECT N = COUNT(*), Id = MIN(w.Id) FROM masterdata.Warehouses w
                     WHERE wc.Id IS NULL AND r.WarehouseInput IS NOT NULL AND w.WarehouseName = r.WarehouseInput) wn
    ),
    ranked AS
    (
        SELECT res.*, DupRank = ROW_NUMBER() OVER (PARTITION BY res.ItemId, res.WarehouseId ORDER BY res.RowNumber)
        FROM res
    ),
    dup AS
    (
        SELECT d.ItemId, d.WarehouseId, N = COUNT(*),
               List = STRING_AGG(CASE WHEN d.DupRank <= 20 THEN CAST(d.RowNumber AS NVARCHAR(12)) END, N', ')
                          WITHIN GROUP (ORDER BY d.RowNumber)
        FROM ranked d
        WHERE d.ItemId IS NOT NULL AND d.WarehouseId IS NOT NULL
        GROUP BY d.ItemId, d.WarehouseId
        HAVING COUNT(*) > 1
    )
    SELECT x.RowNumber,
           Status  = CAST(CASE WHEN k.R BETWEEN 1 AND 9 OR k.R IN (14, 15, 16, 18, 21) THEN N'Error'
                               WHEN k.R IN (10, 13, 17)                          THEN N'Unchanged'
                               WHEN k.R IN (11, 19)                              THEN N'Warning'
                               ELSE N'Valid' END AS NVARCHAR(10)),
           Action  = CAST(CASE WHEN k.R IN (11, 12) THEN N'Remove' WHEN k.R IN (19, 20) THEN N'Set' ELSE N'None' END AS NVARCHAR(10)),
           Message = CAST(CASE k.R
                              WHEN 1  THEN x.ParseError
                              WHEN 2  THEN N'Item Code / Barcode is required.'
                              WHEN 3  THEN N'Item ' + x.ItemInput + N' not found.'
                              WHEN 4  THEN N'Warehouse is required.'
                              WHEN 5  THEN N'Warehouse ' + x.WarehouseInput + N' not found.'
                              WHEN 6  THEN N'Warehouse name ' + x.WarehouseInput + N' matches ' + CAST(x.NameMatches AS NVARCHAR(10)) + N' warehouses: use the code.'
                              WHEN 7  THEN w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot have stock levels.'
                              WHEN 8  THEN N'Warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
                              WHEN 9  THEN N'Item ' + i.ItemCode + N' at ' + w.WarehouseCode + N' is on rows ' + ISNULL(dp.List, N'')
                                           + CASE WHEN dp.N > 20 THEN N' and ' + CAST(dp.N - 20 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                           + N' of the file: keep one row.'
                              WHEN 10 THEN N'No level to remove.'
                              WHEN 11 THEN N'Remove is Yes: Min and Max are ignored.'
                              WHEN 12 THEN wm.Was
                              WHEN 13 THEN N'Nothing to change: Min and Max are empty.'
                              WHEN 14 THEN N'Min is required (a whole number, 0 or more), or put Yes in Remove.'
                              WHEN 15 THEN N'Min must be a whole number, 0 or more.'
                              WHEN 16 THEN N'Max cannot be less than Min.'
                              WHEN 17 THEN N'No change.'
                              WHEN 18 THEN N'Warehouse ' + w.WarehouseCode + N' is inactive: activate it to change its levels.'
                              WHEN 19 THEN N'Item ' + i.ItemCode + N' is inactive: Fill to Max skips it.'
                              WHEN 21 THEN N'Min and Max can be at most 1,000,000,000 pcs.'
                              ELSE wm.Was END AS NVARCHAR(500)),   -- 20: NULL for a new level
           x.ItemInput, x.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive,
           x.WarehouseInput, x.WarehouseId, w.WarehouseCode, w.WarehouseName, b.BranchCode,
           x.MinQuantityBase, x.MaxQuantityBase, x.IsRemove,
           HasLevel       = CAST(CASE WHEN lv.ItemId IS NULL THEN 0 ELSE 1 END AS BIT),
           CurrentMinBase = lv.MinQuantityBase,
           CurrentMaxBase = lv.MaxQuantityBase
    FROM res x
    LEFT JOIN inventory.Items i                ON i.Id = x.ItemId
    LEFT JOIN masterdata.Warehouses w          ON w.Id = x.WarehouseId
    LEFT JOIN masterdata.Branches b            ON b.Id = w.BranchId
    LEFT JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = x.ItemId AND lv.WarehouseId = x.WarehouseId
    LEFT JOIN dup dp                           ON dp.ItemId = x.ItemId AND dp.WarehouseId = x.WarehouseId
    CROSS APPLY (SELECT Was = CASE WHEN lv.ItemId IS NOT NULL
                                   THEN N'Was Min ' + CAST(lv.MinQuantityBase AS NVARCHAR(12)) + N' / '
                                        + CASE WHEN lv.MaxQuantityBase IS NULL THEN N'no Max'
                                               ELSE N'Max ' + CAST(lv.MaxQuantityBase AS NVARCHAR(12)) END + N'.' END) wm
    CROSS APPLY (SELECT R = CASE
            WHEN x.ParseError IS NOT NULL                                                   THEN 1
            WHEN x.ItemInput IS NULL                                                        THEN 2
            WHEN x.ItemId IS NULL                                                           THEN 3
            WHEN x.WarehouseInput IS NULL                                                   THEN 4
            WHEN x.WarehouseId IS NULL AND x.NameMatches = 0                                THEN 5
            WHEN x.WarehouseId IS NULL                                                      THEN 6
            WHEN w.IsTransit = 1                                                            THEN 7
            WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)     THEN 8
            WHEN dp.N > 1                                                                   THEN 9
            WHEN x.IsRemove = 1 AND lv.ItemId IS NULL                                       THEN 10
            WHEN x.IsRemove = 1 AND (x.MinQuantityBase IS NOT NULL OR x.MaxQuantityBase IS NOT NULL) THEN 11
            WHEN x.IsRemove = 1                                                             THEN 12
            WHEN x.MinQuantityBase IS NULL AND x.MaxQuantityBase IS NULL                    THEN 13
            WHEN x.MinQuantityBase IS NULL                                                  THEN 14
            WHEN x.MinQuantityBase < 0                                                      THEN 15
            WHEN x.MinQuantityBase > 1000000000 OR x.MaxQuantityBase > 1000000000            THEN 21
            WHEN x.MaxQuantityBase < x.MinQuantityBase                                      THEN 16
            WHEN lv.ItemId IS NOT NULL AND lv.MinQuantityBase = x.MinQuantityBase
                 AND ISNULL(lv.MaxQuantityBase, -1) = ISNULL(x.MaxQuantityBase, -1)         THEN 17
            WHEN w.IsActive = 0                                                             THEN 18
            WHEN i.IsActive = 0                                                             THEN 19
            ELSE 20 END) k
);

GO

