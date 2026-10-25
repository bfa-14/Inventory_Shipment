/* 13.7 WHO IS TOLD THAT A TRANSFER ORDER WAITS FOR APPROVAL (M10): the active users holding Approve Transfer Orders
   through an active role that is not a system role, the requester left out, by name. The system role (Admin) holds
   every permission (usp_Permission_SyncCatalog) and would get every request, so its holders are told only when nobody
   else qualifies. Each must also hold View Transfer Orders (any of his roles): the email's link opens the order, and
   without it the page and the waiting list answer 403. The right to decide stays the permission (Blocks), whatever
   this list says. */
CREATE   PROCEDURE inventory.usp_TransferOrder_Approvers
    @RequesterId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @A TABLE (UserId INT NOT NULL PRIMARY KEY, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL);

    INSERT INTO @A (UserId, FullName, Email)
    SELECT u.Id, u.FullName, u.Email
    FROM security.Users u
    WHERE u.IsActive = 1
      AND (@RequesterId IS NULL OR u.Id <> @RequesterId)
      AND EXISTS (SELECT 1
                  FROM security.UserRoles ur
                  INNER JOIN security.Roles r            ON r.Id = ur.RoleId AND r.IsActive = 1 AND r.IsSystem = 0
                  INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
                  INNER JOIN security.Permissions p      ON p.Id = rp.PermissionId AND p.Code = N'inventory.transfers.approve'
                  WHERE ur.UserId = u.Id)
      AND security.fn_UserHasPermission(u.Id, N'inventory.transfers.view') = 1;

    IF NOT EXISTS (SELECT 1 FROM @A)
        INSERT INTO @A (UserId, FullName, Email)
        SELECT u.Id, u.FullName, u.Email
        FROM security.Users u
        WHERE u.IsActive = 1
          AND (@RequesterId IS NULL OR u.Id <> @RequesterId)
          AND EXISTS (SELECT 1
                      FROM security.UserRoles ur
                      INNER JOIN security.Roles r            ON r.Id = ur.RoleId AND r.IsActive = 1 AND r.IsSystem = 1
                      INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
                      INNER JOIN security.Permissions p      ON p.Id = rp.PermissionId AND p.Code = N'inventory.transfers.approve'
                      WHERE ur.UserId = u.Id)
          AND security.fn_UserHasPermission(u.Id, N'inventory.transfers.view') = 1;

    SELECT UserId, FullName, Email FROM @A ORDER BY FullName, UserId;
END

GO

