CREATE   PROCEDURE inventory.usp_ItemUnit_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsBase BIT = (SELECT IsBaseUnit FROM inventory.ItemUnits WHERE Id = @Id);
    IF @IsBase IS NULL
        THROW 56006, 'Item unit not found.', 1;
    IF @IsBase = 1
        THROW 56005, 'The Base Unit cannot be deleted. Mark another unit as the base first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.ItemUnits');

    DECLARE @Referenced BIT = 0;
    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    IF @Referenced = 1
        THROW 56003, 'This unit cannot be deleted because it is referenced by transactions.', 1;

    DELETE FROM inventory.ItemUnits WHERE Id = @Id;
END

GO

