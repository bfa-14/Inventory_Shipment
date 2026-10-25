/* ================================================================== 4. The rule: five functions */

-- (92) 1 = THE USER MAY USE EVERY WAREHOUSE: All warehouses, or an active system role (A3). NULL = no user: never
--      refused (rows older than the user stamp; every writer stamps the acting user, W16). An unknown id: 0. For a user
--      with All warehouses: one primary-key seek.
CREATE   FUNCTION security.fn_User_IsUnrestricted (@UserId INT)
RETURNS BIT
AS
BEGIN
    IF @UserId IS NULL RETURN 1;
    IF EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId AND AllWarehouses = 1) RETURN 1;
    IF EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
               WHERE ur.UserId = @UserId AND r.IsSystem = 1 AND r.IsActive = 1) RETURN 1;
    RETURN 0;
END

GO

