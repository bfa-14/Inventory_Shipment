-- branch); the generic reference scan moved to usp_Warehouse_IsReferenced (the same keys: none cascades), with today's
-- sentence.
-- Re-created (92) from the body of script 90: + @UserId (last); the users who ticked the warehouse get a history row
-- "Only: LKS-01 (LKS-02 deleted)" in the DELETE's transaction (W13, A15). The checks and their messages unchanged.
CREATE   PROCEDURE masterdata.usp_Warehouse_Delete
    @Id     INT,
    @UserId INT = NULL        -- (92) who deletes it (the history's ChangedBy)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- (92)

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    -- (90) THE BRANCH'S ON THE WAY WAREHOUSE is the system's: usp_Branch_Delete removes it with its branch.
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsTransit = 1)
    BEGIN
        DECLARE @TransitMsg NVARCHAR(400) = (SELECT w.WarehouseCode + N' is the On the way warehouse of ' + b.BranchCode + N': it is removed with its branch.'
                                             FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                             WHERE w.Id = @Id);
        THROW 52009, @TransitMsg, 1;
    END

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deleted. Designate another warehouse as the Main Warehouse first.', 1;

    /* Said before the generic reference scan below, which would otherwise report a warehouse with
       children as "contains inventory or is referenced by other records" - true, but not the thing
       the reader has to fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @Id)
        THROW 52003, 'This warehouse has warehouses standing under it. Move or delete them first.', 1;

    -- (90) the generic reference scan, held once (ParentId is handled above, in its own words)
    DECLARE @Referenced BIT = 0;
    EXEC masterdata.usp_Warehouse_IsReferenced @Id, @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 52003, 'This warehouse cannot be deleted because it contains inventory or is referenced by other records. You may deactivate the warehouse instead.', 1;

    -- (92) THE DELETE, in one transaction with the history of the users who had ticked the warehouse (W13, A15)
    DECLARE @Code NVARCHAR(20) = (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @Id);
    DECLARE @Suffix NVARCHAR(40) = N' (' + @Code + N' deleted)';
    DECLARE @Had TABLE (UserId INT NOT NULL PRIMARY KEY, BeforeText NVARCHAR(1000) NOT NULL);
    BEGIN TRY
        BEGIN TRANSACTION;
        -- (92) the users who ticked it, in words before the tick goes (a tick left on a user with All warehouses
        --      means nothing: no history row for it)
        INSERT INTO @Had (UserId, BeforeText)
        SELECT uw.UserId, security.fn_User_WarehouseAccessText(uw.UserId)
        FROM security.UserWarehouses uw WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN security.Users u ON u.Id = uw.UserId AND u.AllWarehouses = 0
        WHERE uw.WarehouseId = @Id;
        -- the ticks go first (the cascade would take them with the warehouse; deleted here so that the words after
        -- can be read), then one history row per user: the words without the code + " ({code} deleted)"
        DELETE FROM security.UserWarehouses WHERE WarehouseId = @Id;
        INSERT INTO security.UserWarehouseAudit (UserId, BeforeText, AfterText, ChangedBy)
        SELECT h.UserId, h.BeforeText,
               CASE WHEN LEN(t.AfterText) + LEN(@Suffix) <= 1000 THEN t.AfterText + @Suffix
                    ELSE LEFT(t.AfterText, 1000 - LEN(@Suffix)) + @Suffix END,
               @UserId
        FROM @Had h
        CROSS APPLY (SELECT AfterText = ISNULL(security.fn_User_WarehouseAccessText(h.UserId), N'Only: none')) t;

        DELETE FROM masterdata.Warehouses WHERE Id = @Id;   -- the cascades take 91's levels
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

