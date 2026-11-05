/* ================================================================== 3. reporting.usp_ItemBalance_Warehouses */

-- The warehouses the filter offers, as a tree (ParentId, Level). A user with All warehouses (or a system role) gets
-- every one, the On the way warehouses of transfers too; a restricted user only theirs. Inactive warehouses are offered
-- (they may hold history).
CREATE   PROCEDURE reporting.usp_ItemBalance_Warehouses
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF security.fn_User_IsUnrestricted(@UserId) = 1
        INSERT INTO @Usable (WarehouseId) SELECT Id FROM masterdata.Warehouses;
    ELSE
        INSERT INTO @Usable (WarehouseId)
        SELECT u.WarehouseId
        FROM security.fn_User_Warehouses(@UserId) u
        INNER JOIN masterdata.Warehouses w ON w.Id = u.WarehouseId
        WHERE w.IsTransit = 0;

    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.ParentId, w.Level, w.IsTransit, w.IsActive,
           b.BranchCode,
           HasChildren = CAST(CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id) THEN 1 ELSE 0 END AS BIT)
    FROM @Usable u
    INNER JOIN masterdata.Warehouses w ON w.Id = u.WarehouseId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    ORDER BY w.IsTransit, b.BranchCode, w.WarehouseCode;
END