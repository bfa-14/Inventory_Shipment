/* =====================================================================
   Inventory_Shipment - 02: seed the first administrator
   Run 01_Create_Schema.sql first.

   The password hash below is Argon2id (the exact format the API produces
   and verifies). It corresponds to the password:

        Admin@12345

   Sign in with username 'admin' and that password, then change it from the
   app (or the /api/auth/change-password endpoint) right away.

   To seed a DIFFERENT password instead, don't edit the hash by hand - the
   app can't verify a hand-made one. Generate a matching hash with:

        POST /api/auth/... (or) let the app seed it via Seed:AdminPassword,

   see Database/README for details.
   ===================================================================== */

USE [Inventory_Shipment];
GO

IF NOT EXISTS (SELECT 1 FROM security.Users WHERE Username = N'admin')
BEGIN
    INSERT INTO security.Users (Username, Email, FullName, PasswordHash, Role, IsActive, CreatedAtUtc)
    VALUES
    (
        N'admin',
        N'admin@inventory.local',
        N'System Administrator',
        N'$argon2id$v=19$m=65536,t=3,p=4$VBNCoWx5SHbDzVzA9eLigg==$+UzqpeA7dl9s4K9sLhYxt8fgUiRdElJlfgzvk68uOBA=',
        N'Admin',
        1,
        SYSUTCDATETIME()
    );
    PRINT 'Seeded administrator: admin / Admin@12345  (change this password after first sign-in)';
END
ELSE
BEGIN
    PRINT 'A user named admin already exists - nothing to seed.';
END
GO

SELECT Id, Username, Email, FullName, Role, IsActive, CreatedAtUtc FROM security.Users;
GO
