--      1: UserId, Username, FullName, AllWarehouses, IsSystemAdministrator (an active system role: every warehouse,
--         whatever is stored). No user: 50003.
--      2: the ticks - WarehouseId, WarehouseCode, WarehouseName, BranchId, BranchCode, BranchName, IsActive, ChildCount,
--         GrantedAtUtc, GrantedByName ("-" when unknown), by code.
--      3: UsableCount - the warehouses the ticks give that hold stock (at the bottom of the tree, not On the way).
--      4: the history, the 100 newest - Id, BeforeText, AfterText, ChangedAtUtc, ChangedByName ("-" when unknown).
CREATE   PROCEDURE security.usp_User_Warehouses_Get
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId)
        THROW 50003, 'User not found.', 1;

    SELECT u.Id AS UserId, u.Username, u.FullName, u.AllWarehouses,
           IsSystemAdministrator = CAST(CASE WHEN EXISTS (SELECT 1 FROM security.UserRoles ur
                                                          INNER JOIN security.Roles r ON r.Id = ur.RoleId
                                                          WHERE ur.UserId = u.Id AND r.IsSystem = 1 AND r.IsActive = 1)
                                             THEN 1 ELSE 0 END AS BIT)
    FROM security.Users u
    WHERE u.Id = @UserId;

    SELECT uw.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.IsActive,
           ChildCount    = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           uw.GrantedAtUtc,
           GrantedByName = ISNULL(g.FullName, N'-')
    FROM security.UserWarehouses uw
    INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    LEFT  JOIN security.Users g        ON g.Id = uw.GrantedBy
    WHERE uw.UserId = @UserId
    ORDER BY w.WarehouseCode;

    SELECT UsableCount = COUNT(*)
    FROM security.fn_User_Warehouses(@UserId) x
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    WHERE w.IsTransit = 0
      AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id);

    SELECT TOP (100) a.Id, a.BeforeText, a.AfterText, a.ChangedAtUtc, ChangedByName = ISNULL(c.FullName, N'-')
    FROM security.UserWarehouseAudit a
    LEFT JOIN security.Users c ON c.Id = a.ChangedBy
    WHERE a.UserId = @UserId
    ORDER BY a.ChangedAtUtc DESC, a.Id DESC;
END

GO

