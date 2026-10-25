/* ================================================================== 3. One On the way warehouse per branch */

-- (90) THE BRANCH'S ON THE WAY WAREHOUSE, created when it is missing: the dispatch to one of the branch's warehouses
--      puts its goods there. Its code is the first free of OTW-{branch code}, OTW-B{branch id}, OTW-B{id}-2, -3, ...
--      (a warehouse may already carry the first). Inserted directly, not through usp_Warehouse_Create, which refuses an
--      inactive branch: a branch closed since may still receive what was sent to it before. No transaction of its own:
--      its callers (a branch's creation, a dispatch, the start-up loop below) hold one; the branch's transit row is read
--      WITH (UPDLOCK, HOLDLOCK), so two callers never create two.
CREATE   PROCEDURE masterdata.usp_Warehouse_EnsureTransit
    @BranchId    INT,
    @UserId      INT = NULL,
    @WarehouseId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @WarehouseId = NULL;
    SELECT @WarehouseId = w.Id
    FROM masterdata.Warehouses w WITH (UPDLOCK, HOLDLOCK)
    WHERE w.BranchId = @BranchId AND w.IsTransit = 1;
    IF @WarehouseId IS NOT NULL RETURN;

    DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
    IF @BranchCode IS NULL THROW 52007, 'Branch / Site not found.', 1;

    DECLARE @Code NVARCHAR(20) = UPPER(N'OTW-' + LEFT(@BranchCode, 16));
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @Code)
        SET @Code = N'OTW-B' + CAST(@BranchId AS NVARCHAR(10));
    DECLARE @n INT = 2;
    WHILE EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @Code)
    BEGIN
        SET @Code = N'OTW-B' + CAST(@BranchId AS NVARCHAR(10)) + N'-' + CAST(@n AS NVARCHAR(3));
        SET @n += 1;
    END

    INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive,
                                       ParentId, [Level], IsTransit, AllowOutOfStockOverride, CreatedBy)
    VALUES (@Code, N'On the way to ' + LEFT(@BranchCode, 100) + N' (transfers)', @BranchId, NULL, 0, 1,
            NULL, 1, 1, NULL, @UserId);

    SET @WarehouseId = SCOPE_IDENTITY();
END

GO

