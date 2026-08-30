/* =====================================================================================
   Inventory_Shipment - 03: Security module (roles, permissions, user-role assignments)

   Schema:    security (created if missing)
   Creates:   security.Roles, security.Permissions, security.RolePermissions, security.UserRoles
   Functions: security.fn_UserRoles, security.fn_UserPermissions, security.fn_UserHasPermission
   Procs:     security.usp_Permission_SyncCatalog, security.usp_User_GetAccess, security.usp_User_SetRoles,
              security.usp_Role_SetPermissions, security.usp_Role_Delete
   Seeds:     roles Admin (system), Manager, User; the Security permission catalog;
              Admin gets every permission; existing security.Users.Role values are copied into security.UserRoles.

   Safe to run repeatedly (idempotent). Requires SQL Server 2016 SP1+ (compatibility level 130+)
   for STRING_SPLIT / OPENJSON / CREATE OR ALTER.

   The legacy security.Users.Role column is KEPT by this script so the currently deployed API keeps
   working. Run 04_Security_DropLegacyRoleColumn.sql after the new backend is deployed.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) < 130
BEGIN
    RAISERROR ('Database compatibility level must be 130 or higher. Run: ALTER DATABASE [Inventory_Shipment] SET COMPATIBILITY_LEVEL = 130;', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'security') IS NULL
    EXEC (N'CREATE SCHEMA [security] AUTHORIZATION [dbo];');
GO

IF OBJECT_ID(N'security.Users', N'U') IS NULL
BEGIN
    IF OBJECT_ID(N'dbo.Users', N'U') IS NOT NULL
        RAISERROR ('security.Users was not found but dbo.Users exists: run 05_Migrate_dbo_To_Security.sql first.', 16, 1);
    ELSE
        RAISERROR ('security.Users was not found: run 01_Create_Schema.sql first.', 16, 1);
    RETURN;
END
GO

/* ------------------------------------------------------------------ 1. Tables */

IF OBJECT_ID(N'security.Roles', N'U') IS NULL
BEGIN
    CREATE TABLE security.Roles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        Name         NVARCHAR(50)      NOT NULL,
        Description  NVARCHAR(250)     NULL,
        IsSystem     BIT               NOT NULL CONSTRAINT DF_Roles_IsSystem DEFAULT (0),   -- system roles always hold every permission and cannot be deleted/renamed
        IsActive     BIT               NOT NULL CONSTRAINT DF_Roles_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_Roles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        UpdatedAtUtc DATETIME2(3)      NULL,
        CONSTRAINT PK_Roles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Roles_Name UNIQUE (Name)
    );
    PRINT 'Created security.Roles';
END
GO

IF OBJECT_ID(N'security.Permissions', N'U') IS NULL
BEGIN
    CREATE TABLE security.Permissions
    (
        Id          INT IDENTITY(1,1) NOT NULL,
        Code        NVARCHAR(100)     NOT NULL,   -- stable identifier used by the API, e.g. security.users.view
        Name        NVARCHAR(100)     NOT NULL,
        Module      NVARCHAR(50)      NOT NULL,   -- menu section, e.g. Security
        Description NVARCHAR(250)     NULL,
        SortOrder   INT               NOT NULL CONSTRAINT DF_Permissions_SortOrder DEFAULT (0),
        CONSTRAINT PK_Permissions PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Permissions_Code UNIQUE (Code)
    );
    PRINT 'Created security.Permissions';
END
GO

IF OBJECT_ID(N'security.RolePermissions', N'U') IS NULL
BEGIN
    CREATE TABLE security.RolePermissions
    (
        RoleId       INT          NOT NULL,
        PermissionId INT          NOT NULL,
        GrantedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_RolePermissions_GrantedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_RolePermissions PRIMARY KEY CLUSTERED (RoleId, PermissionId),
        CONSTRAINT FK_RolePermissions_Roles       FOREIGN KEY (RoleId)       REFERENCES security.Roles (Id)       ON DELETE CASCADE,
        CONSTRAINT FK_RolePermissions_Permissions FOREIGN KEY (PermissionId) REFERENCES security.Permissions (Id) ON DELETE CASCADE
    );
    CREATE NONCLUSTERED INDEX IX_RolePermissions_PermissionId ON security.RolePermissions (PermissionId);
    PRINT 'Created security.RolePermissions';
END
GO

IF OBJECT_ID(N'security.UserRoles', N'U') IS NULL
BEGIN
    CREATE TABLE security.UserRoles
    (
        UserId        INT          NOT NULL,
        RoleId        INT          NOT NULL,
        AssignedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_UserRoles_AssignedAtUtc DEFAULT (SYSUTCDATETIME()),
        AssignedBy    INT          NULL,   -- security.Users.Id of the administrator who assigned it (no FK: avoids multiple cascade paths)
        CONSTRAINT PK_UserRoles PRIMARY KEY CLUSTERED (UserId, RoleId),
        CONSTRAINT FK_UserRoles_Users FOREIGN KEY (UserId) REFERENCES security.Users (Id) ON DELETE CASCADE,
        CONSTRAINT FK_UserRoles_Roles FOREIGN KEY (RoleId) REFERENCES security.Roles (Id) ON DELETE CASCADE
    );
    CREATE NONCLUSTERED INDEX IX_UserRoles_RoleId ON security.UserRoles (RoleId);
    PRINT 'Created security.UserRoles';
END
GO

/* ------------------------------------------------------------------ 2. Functions */

-- Active roles of a user
CREATE OR ALTER FUNCTION security.fn_UserRoles (@UserId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT r.Id, r.Name
    FROM security.UserRoles ur
    INNER JOIN security.Roles r ON r.Id = ur.RoleId
    WHERE ur.UserId = @UserId
      AND r.IsActive = 1
);
GO

-- Distinct permission codes a user holds through their active roles
CREATE OR ALTER FUNCTION security.fn_UserPermissions (@UserId INT)
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

-- 1 when the user holds the permission, otherwise 0
CREATE OR ALTER FUNCTION security.fn_UserHasPermission (@UserId INT, @Code NVARCHAR(100))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM security.fn_UserPermissions(@UserId) WHERE Code = @Code) THEN 1 ELSE 0 END;
END
GO

/* ------------------------------------------------------------------ 3. Procedures */

-- Upserts the permission catalog the API defines in code, and makes sure every system role
-- (Admin) holds every permission. Called by the API on start-up.
-- @CatalogJson: [{"code":"security.users.view","name":"View users","module":"Security","description":"...","sortOrder":10}, ...]
CREATE OR ALTER PROCEDURE security.usp_Permission_SyncCatalog
    @CatalogJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        MERGE security.Permissions AS target
        USING
        (
            SELECT j.code, j.name, j.module, j.description, ISNULL(j.sortOrder, 0) AS sortOrder
            FROM OPENJSON(@CatalogJson)
            WITH
            (
                code        NVARCHAR(100) '$.code',
                name        NVARCHAR(100) '$.name',
                module      NVARCHAR(50)  '$.module',
                description NVARCHAR(250) '$.description',
                sortOrder   INT           '$.sortOrder'
            ) AS j
            WHERE j.code IS NOT NULL
        ) AS source
        ON target.Code = source.code
        WHEN MATCHED THEN
            UPDATE SET Name = source.name, Module = source.module, Description = source.description, SortOrder = source.sortOrder
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (Code, Name, Module, Description, SortOrder)
            VALUES (source.code, source.name, source.module, source.description, source.sortOrder);

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT r.Id, p.Id
        FROM security.Roles r
        CROSS JOIN security.Permissions p
        WHERE r.IsSystem = 1
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Two result sets for one user: (1) roles: Id, Name  (2) permissions: Code. Used at login / refresh / me.
CREATE OR ALTER PROCEDURE security.usp_User_GetAccess
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, Name FROM security.fn_UserRoles(@UserId) ORDER BY Name;
    SELECT Code FROM security.fn_UserPermissions(@UserId) ORDER BY Code;
END
GO

-- Replaces the full set of roles of a user. @RoleIds is a comma-separated list of security.Roles.Id ('' = no roles).
-- Error 50003: user not found. 50004: would remove the last active administrator.
CREATE OR ALTER PROCEDURE security.usp_User_SetRoles
    @UserId     INT,
    @RoleIds    NVARCHAR(MAX),
    @AssignedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId)
        THROW 50003, 'User not found.', 1;

    DECLARE @Wanted TABLE (RoleId INT PRIMARY KEY);

    INSERT INTO @Wanted (RoleId)
    SELECT DISTINCT TRY_CAST(s.value AS INT)
    FROM STRING_SPLIT(ISNULL(@RoleIds, N''), ',') AS s
    WHERE LTRIM(RTRIM(s.value)) <> N''
      AND TRY_CAST(s.value AS INT) IS NOT NULL;

    -- Never leave the system without an active administrator.
    IF EXISTS
       (
           SELECT 1
           FROM security.UserRoles ur
           INNER JOIN security.Roles r ON r.Id = ur.RoleId
           WHERE ur.UserId = @UserId AND r.IsSystem = 1
             AND r.Id NOT IN (SELECT RoleId FROM @Wanted)
       )
       AND NOT EXISTS
       (
           SELECT 1
           FROM security.UserRoles ur
           INNER JOIN security.Roles r ON r.Id = ur.RoleId
           INNER JOIN security.Users u ON u.Id = ur.UserId
           WHERE r.IsSystem = 1 AND u.IsActive = 1 AND ur.UserId <> @UserId
       )
        THROW 50004, 'This user is the last active administrator; the Admin role cannot be removed.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE ur
        FROM security.UserRoles ur
        WHERE ur.UserId = @UserId
          AND ur.RoleId NOT IN (SELECT RoleId FROM @Wanted);

        INSERT INTO security.UserRoles (UserId, RoleId, AssignedBy)
        SELECT @UserId, w.RoleId, @AssignedBy
        FROM @Wanted w
        INNER JOIN security.Roles r ON r.Id = w.RoleId
        WHERE NOT EXISTS (SELECT 1 FROM security.UserRoles ur WHERE ur.UserId = @UserId AND ur.RoleId = w.RoleId);

        UPDATE security.Users SET UpdatedAtUtc = SYSUTCDATETIME() WHERE Id = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Replaces the full permission set of a role. @PermissionIds: comma-separated security.Permissions.Id ('' = none).
-- Error 50001: role not found. 50002: system role (its permissions are managed automatically).
CREATE OR ALTER PROCEDURE security.usp_Role_SetPermissions
    @RoleId        INT,
    @PermissionIds NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM security.Roles WHERE Id = @RoleId)
        THROW 50001, 'Role not found.', 1;

    IF EXISTS (SELECT 1 FROM security.Roles WHERE Id = @RoleId AND IsSystem = 1)
        THROW 50002, 'The permissions of a system role cannot be changed; it always holds every permission.', 1;

    DECLARE @Wanted TABLE (PermissionId INT PRIMARY KEY);

    INSERT INTO @Wanted (PermissionId)
    SELECT DISTINCT TRY_CAST(s.value AS INT)
    FROM STRING_SPLIT(ISNULL(@PermissionIds, N''), ',') AS s
    WHERE LTRIM(RTRIM(s.value)) <> N''
      AND TRY_CAST(s.value AS INT) IS NOT NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE rp
        FROM security.RolePermissions rp
        WHERE rp.RoleId = @RoleId
          AND rp.PermissionId NOT IN (SELECT PermissionId FROM @Wanted);

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT @RoleId, w.PermissionId
        FROM @Wanted w
        INNER JOIN security.Permissions p ON p.Id = w.PermissionId
        WHERE NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = @RoleId AND rp.PermissionId = w.PermissionId);

        UPDATE security.Roles SET UpdatedAtUtc = SYSUTCDATETIME() WHERE Id = @RoleId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Deletes a role. Error 50001: not found. 50005: system role. 50006: still assigned to users.
CREATE OR ALTER PROCEDURE security.usp_Role_Delete
    @RoleId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM security.Roles WHERE Id = @RoleId)
        THROW 50001, 'Role not found.', 1;

    IF EXISTS (SELECT 1 FROM security.Roles WHERE Id = @RoleId AND IsSystem = 1)
        THROW 50005, 'System roles cannot be deleted.', 1;

    IF EXISTS (SELECT 1 FROM security.UserRoles WHERE RoleId = @RoleId)
        THROW 50006, 'The role is still assigned to one or more users. Remove it from those users first.', 1;

    DELETE FROM security.Roles WHERE Id = @RoleId;   -- security.RolePermissions rows cascade
END
GO

/* ------------------------------------------------------------------ 4. Seed data */

-- Roles (Admin is the system role)
IF NOT EXISTS (SELECT 1 FROM security.Roles WHERE Name = N'Admin')
    INSERT INTO security.Roles (Name, Description, IsSystem) VALUES (N'Admin', N'Full access. Always holds every permission.', 1);
IF NOT EXISTS (SELECT 1 FROM security.Roles WHERE Name = N'Manager')
    INSERT INTO security.Roles (Name, Description, IsSystem) VALUES (N'Manager', N'Supervises daily operations.', 0);
IF NOT EXISTS (SELECT 1 FROM security.Roles WHERE Name = N'User')
    INSERT INTO security.Roles (Name, Description, IsSystem) VALUES (N'User', N'Standard user.', 0);
GO

-- Security permission catalog (the API syncs the same list on start-up via usp_Permission_SyncCatalog)
MERGE security.Permissions AS target
USING
(
    VALUES
        (N'security.users.view',       N'View users',        N'Security', N'See the list of users and their details.',                              10),
        (N'security.users.create',     N'Create users',      N'Security', N'Add new user accounts.',                                                20),
        (N'security.users.edit',       N'Edit users',        N'Security', N'Change user details, status and roles, and reset passwords.',           30),
        (N'security.roles.view',       N'View roles',        N'Security', N'See roles and the permissions they hold.',                              40),
        (N'security.roles.manage',     N'Manage roles',      N'Security', N'Create, edit and delete roles and assign their permissions.',           50),
        (N'security.permissions.view', N'View permissions',  N'Security', N'See the permission catalog and which roles hold each permission.',      60),
        (N'security.audit.view',       N'View login audit',  N'Security', N'See the sign-in history.',                                              70)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- Admin (every system role) holds every permission
INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE r.IsSystem = 1
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- Manager: read-only access to the Security section (only granted the first time, so later edits are kept)
IF NOT EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Roles r ON r.Id = rp.RoleId WHERE r.Name = N'Manager')
BEGIN
    INSERT INTO security.RolePermissions (RoleId, PermissionId)
    SELECT r.Id, p.Id
    FROM security.Roles r
    CROSS JOIN security.Permissions p
    WHERE r.Name = N'Manager'
      AND p.Code IN (N'security.users.view', N'security.roles.view', N'security.permissions.view', N'security.audit.view');
END
GO

/* ------------------------------------------------------------------ 5. Migrate the legacy single-role column */

-- Copies security.Users.Role ('Admin' | 'Manager' | 'User') into security.UserRoles for users that have no roles yet.
-- Dynamic SQL so this batch still compiles after the column has been dropped (script 04).
IF COL_LENGTH(N'security.Users', N'Role') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
        INSERT INTO security.UserRoles (UserId, RoleId)
        SELECT u.Id, r.Id
        FROM security.Users u
        INNER JOIN security.Roles r ON r.Name = u.Role
        WHERE NOT EXISTS (SELECT 1 FROM security.UserRoles ur WHERE ur.UserId = u.Id);';
    PRINT 'Copied security.Users.Role values into security.UserRoles';
END
GO

-- Safety net: any admin account that still has no role at all gets the Admin role.
IF NOT EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId WHERE r.IsSystem = 1)
BEGIN
    INSERT INTO security.UserRoles (UserId, RoleId)
    SELECT u.Id, r.Id
    FROM security.Users u
    CROSS JOIN security.Roles r
    WHERE u.Username = N'admin' AND r.Name = N'Admin'
      AND NOT EXISTS (SELECT 1 FROM security.UserRoles ur WHERE ur.UserId = u.Id AND ur.RoleId = r.Id);
END
GO

/* ------------------------------------------------------------------ 6. Report */

SELECT r.Name AS [Role], r.IsSystem,
       (SELECT COUNT(*) FROM security.UserRoles ur WHERE ur.RoleId = r.Id)       AS Users,
       (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.RoleId = r.Id) AS Permissions
FROM security.Roles r
ORDER BY r.Name;

SELECT u.Username,
       ISNULL(STUFF((SELECT N', ' + r.Name
                     FROM security.UserRoles ur
                     INNER JOIN security.Roles r ON r.Id = ur.RoleId
                     WHERE ur.UserId = u.Id
                     ORDER BY r.Name
                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'(no roles)') AS Roles
FROM security.Users u
ORDER BY u.Username;

PRINT 'Security module is ready.';
GO
