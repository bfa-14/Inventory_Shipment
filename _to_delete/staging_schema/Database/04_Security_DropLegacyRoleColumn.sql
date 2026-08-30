/* =====================================================================================
   Inventory_Shipment - 04: drop the legacy single-role column security.Users.Role

   Run ONLY after the new backend (roles via security.UserRoles) is deployed and 03_Security_RBAC.sql
   has been run. Until then the old API still reads this column.
   Idempotent; the API's embedded schema also contains this step, so it may already be done.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'security.Users', N'Role') IS NOT NULL
BEGIN
    -- Make sure nobody loses their role: copy any remaining values first.
    EXEC sp_executesql N'
        INSERT INTO security.UserRoles (UserId, RoleId)
        SELECT u.Id, r.Id
        FROM security.Users u
        INNER JOIN security.Roles r ON r.Name = u.Role
        WHERE NOT EXISTS (SELECT 1 FROM security.UserRoles ur WHERE ur.UserId = u.Id);';

    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Users_Role' AND parent_object_id = OBJECT_ID(N'security.Users'))
        EXEC sp_executesql N'ALTER TABLE security.Users DROP CONSTRAINT CK_Users_Role;';

    IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'DF_Users_Role' AND parent_object_id = OBJECT_ID(N'security.Users'))
        EXEC sp_executesql N'ALTER TABLE security.Users DROP CONSTRAINT DF_Users_Role;';

    EXEC sp_executesql N'ALTER TABLE security.Users DROP COLUMN Role;';

    PRINT 'Dropped legacy column security.Users.Role';
END
ELSE
    PRINT 'security.Users.Role is already gone - nothing to do.';
GO
