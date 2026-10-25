-- branch that never received a transfer); one that a transfer used is kept, and then references the branch, which is
-- refused with today's sentence (51003). One transaction now: the On the way warehouse is deleted only with its branch.
-- The scan of every reference to the branch runs FIRST (its On the way warehouse not counted), and nothing is deleted
-- before it is done: a refused delete - the usual case, a branch in use - never holds a deleted warehouse row while the
-- scan reads the ledger.
CREATE   PROCEDURE masterdata.usp_Branch_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                                                     -- (90)

    BEGIN TRY
    BEGIN TRANSACTION;                                                     -- (90)

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id)
        THROW 51006, 'Branch not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id AND IsMainBranch = 1)
        THROW 51005, 'The Main Branch cannot be deleted. Designate another branch as the Main Branch first.', 1;

    -- (90) ITS ON THE WAY WAREHOUSE: not a reference of the branch by itself (the scan below leaves it out); a reference
    --      when anything references IT (a transfer used it). Deleted with the branch, after every check.
    DECLARE @TransitId INT = (SELECT Id FROM masterdata.Warehouses WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @Id AND IsTransit = 1);

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id'
        + CASE WHEN t.object_id = OBJECT_ID(N'masterdata.Warehouses')
               THEN N' AND (@TransitId IS NULL OR Id <> @TransitId)' ELSE N'' END                   -- (90)
        + N') SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Branches');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @TransitId INT, @Referenced BIT OUTPUT',
                           @Id = @Id, @TransitId = @TransitId, @Referenced = @Referenced OUTPUT;   -- (90) + @TransitId

    IF @Referenced = 0 AND @TransitId IS NOT NULL                          -- (90)
        EXEC masterdata.usp_Warehouse_IsReferenced @TransitId, @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 51003, 'This branch cannot be deleted because it is referenced by other records. You may deactivate the branch instead.', 1;

    IF @TransitId IS NOT NULL                                              -- (90)
        DELETE FROM masterdata.Warehouses WHERE Id = @TransitId;

    DELETE FROM masterdata.Branches WHERE Id = @Id;

    COMMIT TRANSACTION;                                                    -- (90)
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

