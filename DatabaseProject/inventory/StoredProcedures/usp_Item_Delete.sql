/* (91) DELETE AN ITEM never transacted, with its units and files - and its stock levels, which the cascading key
   deletes with it (L5; their history stays, and says so: a "Removed" row per level, from Item Definition, by @UserId -
   S4). Only a key that does NOT cascade is a reference: a cascading child (the levels) is owned by the item. 56003 /
   56006 unchanged. */
-- Re-created (91) from the body of script 11: both generic scans + AND fk.delete_referential_action = 0; + @UserId and
-- the levels' "Removed" audit rows.
CREATE   PROCEDURE inventory.usp_Item_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;

    DECLARE @Referenced BIT = 0, @sql NVARCHAR(MAX) = N'';

    -- References to the item itself (excluding its own child tables).
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.Items')
      AND fk.parent_object_id NOT IN (OBJECT_ID(N'inventory.ItemUnits'), OBJECT_ID(N'inventory.ItemFiles'))
      AND fk.delete_referential_action = 0;   -- (91) a cascading child (the stock levels) is owned, not a reference

    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    -- References to any of the item's units (e.g. future transaction lines storing ItemUnitId).
    IF @Referenced = 0
    BEGIN
        SET @sql = N'';
        SELECT @sql = @sql
            + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' x'
            + N' INNER JOIN inventory.ItemUnits iu ON iu.Id = x.' + QUOTENAME(c.name)
            + N' WHERE iu.ItemId = @Id) SET @Referenced = 1;' + NCHAR(10)
        FROM sys.foreign_keys fk
        INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
        INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.ItemUnits')
          AND fk.delete_referential_action = 0;   -- (91) a cascading child is owned, not a reference

        IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    END

    IF @Referenced = 1
        THROW 56003, 'This item cannot be deleted because it is referenced by inventory or transactions. You may deactivate it instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        -- (91) the levels go with the item (the cascading key): their history records it (S4)
        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, UserId)
        SELECT lv.ItemId, lv.WarehouseId, N'Removed', lv.MinQuantityBase, lv.MaxQuantityBase, NULL, NULL, N'ItemCard', @UserId
        FROM inventory.ItemWarehouseLevels lv
        WHERE lv.ItemId = @Id;
        DELETE FROM inventory.ItemFiles WHERE ItemId = @Id;
        DELETE FROM inventory.ItemUnits WHERE ItemId = @Id;
        DELETE FROM inventory.Items WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

