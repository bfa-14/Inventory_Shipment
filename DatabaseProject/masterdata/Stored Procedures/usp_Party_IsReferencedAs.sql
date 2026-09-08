-- SupplierId / ClientId / SalesmanId / EmployeeId (role-specific) or PartyId (any role).
CREATE   PROCEDURE masterdata.usp_Party_IsReferencedAs
    @Id         INT,
    @Role       NVARCHAR(20),   -- Supplier | Client | Salesman | Employee | NULL = any reference at all
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
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Parties')
      AND (@Role IS NULL OR c.name LIKE @Role + N'%' OR c.name LIKE N'Party%');

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
END