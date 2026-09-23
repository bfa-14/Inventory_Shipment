-- or any of its units (future stock/purchase/invoice lines). sys.foreign_keys covers new tables automatically.
CREATE   PROCEDURE inventory.usp_Item_Delete
    @Id INT
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
      AND fk.parent_object_id NOT IN (OBJECT_ID(N'inventory.ItemUnits'), OBJECT_ID(N'inventory.ItemFiles'));

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
        WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.ItemUnits');

        IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    END

    IF @Referenced = 1
        THROW 56003, 'This item cannot be deleted because it is referenced by inventory or transactions. You may deactivate it instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
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

