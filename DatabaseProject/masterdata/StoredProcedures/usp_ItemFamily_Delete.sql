-- reads sys.foreign_keys EXCLUDING the tree's own self-reference (children are reported as
-- 54005 with their own message), so future tables (items...) are covered automatically.
CREATE   PROCEDURE masterdata.usp_ItemFamily_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @Id)
        THROW 54006, 'Item family not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE ParentId = @Id)
        THROW 54005, 'This family cannot be deleted because it contains child families. Delete or move the children first, or deactivate the family instead.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.ItemFamilies')
      AND fk.parent_object_id   <> OBJECT_ID(N'masterdata.ItemFamilies');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 54003, 'This family cannot be deleted because it is assigned to existing items or other records. You may deactivate it instead.', 1;

    DELETE FROM masterdata.ItemFamilies WHERE Id = @Id;
END

GO

