--      1: one row per tick of a user with "Only these warehouses" - UserId, WarehouseId, WarehouseCode, WarehouseName,
--         BranchCode, IsActive, ChildCount, by user and code.
--      2: one row per user - UserId, AllWarehouses, IsSystemAdministrator.
CREATE   PROCEDURE security.usp_User_WarehouseSummaries
AS
BEGIN
    SET NOCOUNT ON;

    SELECT uw.UserId, uw.WarehouseId, w.WarehouseCode, w.WarehouseName, b.BranchCode, w.IsActive,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
    FROM security.UserWarehouses uw
    INNER JOIN security.Users u        ON u.Id = uw.UserId AND u.AllWarehouses = 0
    INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    ORDER BY uw.UserId, w.WarehouseCode;

    SELECT u.Id AS UserId, u.AllWarehouses,
           IsSystemAdministrator = CAST(CASE WHEN EXISTS (SELECT 1 FROM security.UserRoles ur
                                                          INNER JOIN security.Roles r ON r.Id = ur.RoleId
                                                          WHERE ur.UserId = u.Id AND r.IsSystem = 1 AND r.IsActive = 1)
                                             THEN 1 ELSE 0 END AS BIT)
    FROM security.Users u
    ORDER BY u.Id;
END

GO

