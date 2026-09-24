CREATE   FUNCTION security.fn_UserPermissions (@UserId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT DISTINCT p.Code
    FROM security.UserRoles ur
    INNER JOIN security.Roles r            ON r.Id = ur.RoleId AND r.IsActive = 1
    INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
    INNER JOIN security.Permissions p      ON p.Id = rp.PermissionId
    WHERE ur.UserId = @UserId
);

GO

