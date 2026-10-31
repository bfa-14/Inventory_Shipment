/* ================================================================== 11. Warehouses, branches and items: the On the way rules */

-- (90) DOES ANYTHING REFERENCE THE WAREHOUSE? The generic foreign-key scan of script 28's usp_Warehouse_Delete, held
--      once here: every foreign key to masterdata.Warehouses (so every future table is covered without changing this
--      procedure) but the warehouses' own ParentId (the delete says children in its own words) and a key that CASCADES
--      on delete (a cascading child is owned by the warehouse, not a reference to it: none exists before script 90).
--      Read by usp_Warehouse_Delete and by usp_Branch_Delete for the branch's On the way warehouse.
CREATE   PROCEDURE masterdata.usp_Warehouse_IsReferenced
    @Id         INT,
    @Referenced BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Referenced = 0;
    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Warehouses')
      -- ParentId is said by the delete, in its own words.
      AND NOT (t.object_id = OBJECT_ID(N'masterdata.Warehouses') AND c.name = N'ParentId')
      -- a cascading child is owned, not a reference
      AND fk.delete_referential_action = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
END

GO

