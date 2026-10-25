-- branch); the generic reference scan moved to usp_Warehouse_IsReferenced (the same keys: none cascades), with today's
-- sentence.
CREATE   PROCEDURE masterdata.usp_Warehouse_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

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

    DELETE FROM masterdata.Warehouses WHERE Id = @Id;
END

GO

