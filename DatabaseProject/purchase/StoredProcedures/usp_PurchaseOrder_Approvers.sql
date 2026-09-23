
/* ================================================================== 6. Approval procedures */

-- Who receives approval requests: active users of a NON-system role holding purchase.orders.approve, with an email.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_Approvers
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT u.Id AS UserId, u.FullName, u.Email
    FROM security.Users u
    INNER JOIN security.UserRoles ur      ON ur.UserId = u.Id
    INNER JOIN security.Roles r           ON r.Id = ur.RoleId AND r.IsSystem = 0
    INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
    INNER JOIN security.Permissions p     ON p.Id = rp.PermissionId AND p.Code = N'purchase.orders.approve'
    WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
    ORDER BY u.FullName;
END

GO

