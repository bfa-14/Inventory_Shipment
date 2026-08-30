/* =====================================================================
   Inventory_Shipment - 02: seed the first administrator (schema: security)
   Run 01_Create_Schema.sql first (and 03_Security_RBAC.sql if you want roles).

   Works in both database states:
     - before 04 (legacy column security.Users.Role still exists)  -> Role = 'Admin' is set
     - after  04 (roles live in security.UserRoles)                 -> the Admin role is assigned

   The password hash is Argon2id, the exact format the API produces and
   verifies. It corresponds to the password:   Admin@12345
   Sign in as 'admin' and change the password right away. To seed a
   different password, let the app do it (Seed:AdminPassword) - a hash
   made by hand cannot be verified.
   ===================================================================== */

USE [Inventory_Shipment];
GO

DECLARE @hash NVARCHAR(512) =
    N'$argon2id$v=19$m=65536,t=3,p=4$VBNCoWx5SHbDzVzA9eLigg==$+UzqpeA7dl9s4K9sLhYxt8fgUiRdElJlfgzvk68uOBA=';

IF NOT EXISTS (SELECT 1 FROM security.Users WHERE Username = N'admin')
BEGIN
    INSERT INTO security.Users (Username, Email, FullName, PasswordHash, IsActive, CreatedAtUtc)
    VALUES (N'admin', N'admin@inventory.local', N'System Administrator', @hash, 1, SYSUTCDATETIME());
    PRINT 'Seeded administrator: admin / Admin@12345  (change this password after first sign-in)';
END
ELSE
BEGIN
    PRINT 'A user named admin already exists - nothing to seed.';
END

/* Legacy single-role column (only exists before 04_Security_DropLegacyRoleColumn.sql has run).
   Dynamic SQL so this batch compiles even when the column is gone. */
IF COL_LENGTH(N'security.Users', N'Role') IS NOT NULL
BEGIN
    EXEC sp_executesql N'UPDATE security.Users SET Role = N''Admin'' WHERE Username = N''admin'' AND Role <> N''Admin'';';
    PRINT 'Legacy column security.Users.Role set to Admin';
END
GO

/* Roles & permissions module (03): make sure admin holds the Admin system role. */
IF OBJECT_ID(N'security.UserRoles', N'U') IS NOT NULL AND OBJECT_ID(N'security.Roles', N'U') IS NOT NULL
BEGIN
    INSERT INTO security.UserRoles (UserId, RoleId)
    SELECT u.Id, r.Id
    FROM security.Users u
    CROSS JOIN security.Roles r
    WHERE u.Username = N'admin'
      AND r.Name = N'Admin'
      AND NOT EXISTS (SELECT 1 FROM security.UserRoles ur WHERE ur.UserId = u.Id AND ur.RoleId = r.Id);

    IF @@ROWCOUNT > 0 PRINT 'Assigned the Admin role to admin';
    ELSE PRINT 'admin already holds the Admin role';
END
GO

/* Report (dynamic so it compiles whether or not the roles tables exist). */
IF OBJECT_ID(N'security.UserRoles', N'U') IS NOT NULL
    EXEC sp_executesql N'
        SELECT u.Id, u.Username, u.Email, u.FullName, u.IsActive, u.CreatedAtUtc,
               ISNULL(STUFF((SELECT N'', '' + r.Name
                             FROM security.UserRoles ur
                             INNER JOIN security.Roles r ON r.Id = ur.RoleId
                             WHERE ur.UserId = u.Id
                             ORDER BY r.Name
                             FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N''''), N''(no roles)'') AS Roles
        FROM security.Users u
        ORDER BY u.Username;';
ELSE
    SELECT Id, Username, Email, FullName, IsActive, CreatedAtUtc FROM security.Users ORDER BY Username;
GO
