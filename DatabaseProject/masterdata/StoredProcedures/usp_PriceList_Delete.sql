CREATE   PROCEDURE masterdata.usp_PriceList_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.PriceLists');

    DECLARE @Referenced BIT = 0;
    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    IF @Referenced = 1
        THROW 58003, 'This price list cannot be deleted because it contains prices or is referenced by other records. You may deactivate it instead.', 1;

    DELETE FROM masterdata.PriceLists WHERE Id = @Id;
END

GO

