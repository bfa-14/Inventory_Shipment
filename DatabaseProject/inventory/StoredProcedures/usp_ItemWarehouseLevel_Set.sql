/* (91) SET AN ITEM'S LEVELS IN ONE OR MORE WAREHOUSES (Item Definition's card, Stock Levels), all or nothing. The checks,
   the first failing row by warehouse code (56000): the warehouse exists, is not On the way, has no warehouses under
   it, is active (a new or changed level only: L6), Min is a whole number 0 or more, Min and Max are at most
   1,000,000,000 pcs, Max is not below Min. Then, in the transaction, each row sent with a RowVersion is compared with
   the level as it stands, read WITH (UPDLOCK, HOLDLOCK) (56004: removed / changed by another user); a row without one
   is a NEW level: when somebody else has set one there meanwhile with another Min or Max, 56004 "... was added by
   another user" - never a silent overwrite.
   An unchanged row is neither rewritten nor audited. @Source ItemCard | StockLevels (anything else: ItemCard). No
   result set. */
CREATE   PROCEDURE inventory.usp_ItemWarehouseLevel_Set
    @ItemId INT,
    @Levels inventory.tvp_ItemWarehouseLevel READONLY,
    @Source NVARCHAR(20) = N'ItemCard',
    @UserId INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Source IS NULL OR @Source NOT IN (N'ItemCard', N'StockLevels') SET @Source = N'ItemCard';

    DECLARE @ItemCode NVARCHAR(30), @Msg NVARCHAR(400);

    SELECT @ItemCode = ItemCode FROM inventory.Items WHERE Id = @ItemId;
    IF @ItemCode IS NULL THROW 56006, 'Item not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Levels) THROW 56000, 'Choose at least one warehouse.', 1;

    -- The first failing row, by warehouse code (a warehouse not found first)
    SELECT TOP (1) @Msg = m.Message
    FROM @Levels l
    LEFT JOIN masterdata.Warehouses w          ON w.Id = l.WarehouseId
    LEFT JOIN inventory.ItemWarehouseLevels cur ON cur.ItemId = @ItemId AND cur.WarehouseId = l.WarehouseId
    CROSS APPLY (SELECT Message = CASE
            WHEN w.Id IS NULL THEN N'A warehouse was not found.'
            WHEN w.IsTransit = 1
                THEN w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot have stock levels.'
            WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
                THEN N'Warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
            WHEN w.IsActive = 0
                 AND NOT (cur.ItemId IS NOT NULL AND cur.MinQuantityBase = l.MinQuantityBase
                          AND ISNULL(cur.MaxQuantityBase, -1) = ISNULL(l.MaxQuantityBase, -1))
                THEN N'Warehouse ' + w.WarehouseCode + N' is inactive: activate it to change its levels.'
            WHEN l.MinQuantityBase IS NULL OR l.MinQuantityBase < 0
                THEN w.WarehouseCode + N': Min must be a whole number, 0 or more.'
            WHEN l.MinQuantityBase > 1000000000 OR l.MaxQuantityBase > 1000000000
                THEN w.WarehouseCode + N': Min and Max can be at most 1,000,000,000 pcs.'
            WHEN l.MaxQuantityBase < l.MinQuantityBase
                THEN w.WarehouseCode + N': Max cannot be less than Min.' END) m
    WHERE m.Message IS NOT NULL
    ORDER BY w.WarehouseCode;
    IF @Msg IS NOT NULL THROW 56000, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- The levels as they stand, locked until the commit
        DECLARE @Cur TABLE (WarehouseId INT NOT NULL PRIMARY KEY, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL, RowVersion BINARY(8) NOT NULL);
        INSERT INTO @Cur (WarehouseId, MinQuantityBase, MaxQuantityBase, RowVersion)
        SELECT lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase, lv.RowVersion
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        WHERE lv.ItemId = @ItemId AND lv.WarehouseId IN (SELECT l.WarehouseId FROM @Levels l);

        -- Somebody else removed or changed a level the page read, or added one where the page read none - a row sent
        -- without a RowVersion is a NEW level: it never replaces one somebody else has just set (unless it is the same
        -- Min and Max, which loses nothing). The first by warehouse code.
        SELECT TOP (1) @Msg = N'The stock level of ' + @ItemCode + N' at ' + w.WarehouseCode
                              + CASE WHEN l.RowVersion IS NULL     THEN N' was added by another user. Reload and try again.'
                                     WHEN c.WarehouseId IS NULL    THEN N' was removed by another user. Reload and try again.'
                                     ELSE N' was changed by another user. Reload and try again.' END
        FROM @Levels l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        LEFT  JOIN @Cur c ON c.WarehouseId = l.WarehouseId
        WHERE (l.RowVersion IS NOT NULL AND (c.WarehouseId IS NULL OR c.RowVersion <> l.RowVersion))
           OR (l.RowVersion IS NULL AND c.WarehouseId IS NOT NULL
               AND (c.MinQuantityBase <> l.MinQuantityBase OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(l.MaxQuantityBase, -1)))
        ORDER BY w.WarehouseCode;
        IF @Msg IS NOT NULL THROW 56004, @Msg, 1;

        -- The audit of each row that differs
        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, UserId)
        SELECT @ItemId, l.WarehouseId, CASE WHEN c.WarehouseId IS NULL THEN N'Added' ELSE N'Changed' END,
               c.MinQuantityBase, c.MaxQuantityBase, l.MinQuantityBase, l.MaxQuantityBase, @Source, @UserId
        FROM @Levels l
        LEFT JOIN @Cur c ON c.WarehouseId = l.WarehouseId
        WHERE c.WarehouseId IS NULL
           OR c.MinQuantityBase <> l.MinQuantityBase
           OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(l.MaxQuantityBase, -1);

        MERGE inventory.ItemWarehouseLevels WITH (HOLDLOCK) AS t
        USING (SELECT l.WarehouseId, l.MinQuantityBase, l.MaxQuantityBase FROM @Levels l) AS s
        ON t.ItemId = @ItemId AND t.WarehouseId = s.WarehouseId
        WHEN MATCHED AND (t.MinQuantityBase <> s.MinQuantityBase OR ISNULL(t.MaxQuantityBase, -1) <> ISNULL(s.MaxQuantityBase, -1)) THEN
            UPDATE SET MinQuantityBase = s.MinQuantityBase, MaxQuantityBase = s.MaxQuantityBase,
                       UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase, CreatedBy, UpdatedBy)
            VALUES (@ItemId, s.WarehouseId, s.MinQuantityBase, s.MaxQuantityBase, @UserId, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

