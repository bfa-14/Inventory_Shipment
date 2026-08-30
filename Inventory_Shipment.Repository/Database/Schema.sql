/* =====================================================================================
   Inventory_Shipment - embedded schema, applied on every start-up by DatabaseInitializer.

   Generated from Database\05, 01, 03 and 04. Split into batches on lines containing only GO;
   every batch is idempotent. Each module owns one schema: security here, later inventory and
   shipment. Nothing is created in dbo.
   ===================================================================================== */

-- ===== 05: move existing dbo objects into the [security] schema =====

/* =====================================================================================
   Inventory_Shipment - 05: move the security objects from dbo to the [security] schema

   For databases that were created with the earlier scripts (objects in dbo). New databases
   created with 01/03 already use the security schema and this script does nothing.

   What it does (idempotent, keeps all data):
     1. creates the schema [security] if missing
     2. drops the old dbo routines (their bodies point at dbo tables; 03_Security_RBAC.sql re-creates
        them in the security schema)
     3. transfers the tables Users, RefreshTokens, LoginAudit, Roles, Permissions, RolePermissions,
        UserRoles from dbo to security (constraints, indexes, foreign keys and rows move with them)

   Order for an existing database:  05  ->  03_Security_RBAC.sql  ->  (04 after the new backend is deployed)
   The API embeds the same steps in Repository\Database\Schema.sql, so starting the new build also migrates.
   ===================================================================================== */


IF SCHEMA_ID(N'security') IS NULL
    EXEC (N'CREATE SCHEMA [security] AUTHORIZATION [dbo];');
GO

/* 2. old routines in dbo */
DROP PROCEDURE IF EXISTS dbo.usp_Permission_SyncCatalog;
DROP PROCEDURE IF EXISTS dbo.usp_User_GetAccess;
DROP PROCEDURE IF EXISTS dbo.usp_User_SetRoles;
DROP PROCEDURE IF EXISTS dbo.usp_Role_SetPermissions;
DROP PROCEDURE IF EXISTS dbo.usp_Role_Delete;
DROP FUNCTION  IF EXISTS dbo.fn_UserHasPermission;
DROP FUNCTION  IF EXISTS dbo.fn_UserPermissions;
DROP FUNCTION  IF EXISTS dbo.fn_UserRoles;
GO

/* 3. tables */
DECLARE @tables TABLE (Name sysname NOT NULL);
INSERT INTO @tables (Name)
VALUES (N'Users'), (N'RefreshTokens'), (N'LoginAudit'), (N'Roles'), (N'Permissions'), (N'RolePermissions'), (N'UserRoles');

DECLARE @name sysname, @sql NVARCHAR(400);
DECLARE tables_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT Name FROM @tables;
OPEN tables_cursor;
FETCH NEXT FROM tables_cursor INTO @name;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'dbo.' + @name, N'U') IS NOT NULL AND OBJECT_ID(N'security.' + @name, N'U') IS NULL
    BEGIN
        SET @sql = N'ALTER SCHEMA security TRANSFER dbo.' + QUOTENAME(@name) + N';';
        EXEC sp_executesql @sql;
        PRINT 'Moved dbo.' + @name + ' -> security.' + @name;
    END
    ELSE IF OBJECT_ID(N'dbo.' + @name, N'U') IS NOT NULL AND OBJECT_ID(N'security.' + @name, N'U') IS NOT NULL
    BEGIN
        PRINT 'WARNING: both dbo.' + @name + ' and security.' + @name + ' exist. security.' + @name +
              ' is the one the application uses; dbo.' + @name + ' was left untouched - merge or drop it by hand.';
    END

    FETCH NEXT FROM tables_cursor INTO @name;
END

CLOSE tables_cursor;
DEALLOCATE tables_cursor;
GO


-- ===== 01: security schema - Users / RefreshTokens / LoginAudit =====

/* =====================================================================
   Inventory_Shipment - 01: database + [security] schema (users, refresh tokens, login audit)
   Run this in SSMS (it is safe to run more than once - every object is
   guarded with an existence check).
   The application also applies this same schema automatically on start-up,
   so running it by hand is optional.
   ===================================================================== */

/* Every module gets its own schema: security (this script), inventory, shipment. */
IF SCHEMA_ID(N'security') IS NULL
    EXEC (N'CREATE SCHEMA [security] AUTHORIZATION [dbo];');
GO

IF OBJECT_ID(N'security.Users', N'U') IS NULL
BEGIN
    CREATE TABLE security.Users
    (
        Id                  INT IDENTITY(1,1) NOT NULL,
        Username            NVARCHAR(50)      NOT NULL,
        Email               NVARCHAR(256)     NOT NULL,
        FullName            NVARCHAR(100)     NOT NULL,
        PasswordHash        NVARCHAR(512)     NOT NULL,
        Role                NVARCHAR(30)      NOT NULL CONSTRAINT DF_Users_Role DEFAULT (N'User'),
        IsActive            BIT               NOT NULL CONSTRAINT DF_Users_IsActive DEFAULT (1),
        FailedLoginAttempts INT               NOT NULL CONSTRAINT DF_Users_FailedLoginAttempts DEFAULT (0),
        LockoutEndUtc       DATETIME2(3)      NULL,
        LastLoginAtUtc      DATETIME2(3)      NULL,
        CreatedAtUtc        DATETIME2(3)      NOT NULL CONSTRAINT DF_Users_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        UpdatedAtUtc        DATETIME2(3)      NULL,
        CONSTRAINT PK_Users PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Users_Username UNIQUE (Username),
        CONSTRAINT UQ_Users_Email UNIQUE (Email),
        CONSTRAINT CK_Users_Role CHECK (Role IN (N'Admin', N'Manager', N'User'))
    );
    PRINT 'Created table security.Users';
END
GO

IF OBJECT_ID(N'security.RefreshTokens', N'U') IS NULL
BEGIN
    CREATE TABLE security.RefreshTokens
    (
        Id                  BIGINT IDENTITY(1,1) NOT NULL,
        UserId              INT           NOT NULL,
        TokenHash           NVARCHAR(64)  NOT NULL,   -- SHA-256 (hex) of the raw token; the raw token is never stored
        ExpiresAtUtc        DATETIME2(3)  NOT NULL,
        CreatedAtUtc        DATETIME2(3)  NOT NULL CONSTRAINT DF_RefreshTokens_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedByIp         NVARCHAR(45)  NULL,
        RevokedAtUtc        DATETIME2(3)  NULL,
        RevokedByIp         NVARCHAR(45)  NULL,
        ReplacedByTokenHash NVARCHAR(64)  NULL,
        RevokeReason        NVARCHAR(100) NULL,
        CONSTRAINT PK_RefreshTokens PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_RefreshTokens_TokenHash UNIQUE (TokenHash),
        CONSTRAINT FK_RefreshTokens_Users FOREIGN KEY (UserId) REFERENCES security.Users (Id) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX IX_RefreshTokens_UserId ON security.RefreshTokens (UserId);
    PRINT 'Created table security.RefreshTokens';
END
GO

IF OBJECT_ID(N'security.LoginAudit', N'U') IS NULL
BEGIN
    CREATE TABLE security.LoginAudit
    (
        Id             BIGINT IDENTITY(1,1) NOT NULL,
        Username       NVARCHAR(256) NOT NULL,
        UserId         INT           NULL,
        Succeeded      BIT           NOT NULL,
        FailureReason  NVARCHAR(100) NULL,
        IpAddress      NVARCHAR(45)  NULL,
        UserAgent      NVARCHAR(512) NULL,
        AttemptedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_LoginAudit_AttemptedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_LoginAudit PRIMARY KEY CLUSTERED (Id)
    );

    CREATE NONCLUSTERED INDEX IX_LoginAudit_Username_AttemptedAtUtc ON security.LoginAudit (Username, AttemptedAtUtc DESC);
    PRINT 'Created table security.LoginAudit';
END
GO

PRINT 'security schema is ready.';
GO

-- ===== 03: Security module (roles / permissions) =====

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


-- ===== 04: drop legacy security.Users.Role =====

/* =====================================================================================
   Inventory_Shipment - 04: drop the legacy single-role column security.Users.Role

   Run ONLY after the new backend (roles via security.UserRoles) is deployed and 03_Security_RBAC.sql
   has been run. Until then the old API still reads this column.
   Idempotent; the API's embedded schema also contains this step, so it may already be done.
   ===================================================================================== */

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
<<<<<<< HEAD

-- ===== 06: Master Data - Branches =====

/* =====================================================================================
   Inventory_Shipment - 06: Master Data - Branches / Sites   (user story US-MD-001)

   Schema:  masterdata  (created if missing). One schema per module: security, masterdata,
            inventory, shipment - nothing in dbo.
   Table:   masterdata.Branches
   Procs:   masterdata.usp_Branch_Search, usp_Branch_Get, usp_Branch_Create, usp_Branch_Update,
            usp_Branch_SetActive, usp_Branch_Delete, usp_Branch_GetMain
   Seeds:   permissions masterdata.branches.view / create / edit / delete (module "Master Data"),
            granted to every system role (Admin) and view-only to Manager; a first main branch
            BR-001 "Head Office" when the table is empty.

   Business rules enforced here (error numbers are read by the API):
     51000  validation (required field / invalid value)
     51001  Branch Code already exists
     51002  another active branch is already the Main Branch (client must confirm the replacement:
            call again with @ReplaceMainBranch = 1)
     51003  branch is referenced by other records - cannot be deleted (deactivate instead)
     51004  concurrency conflict (RowVersion changed)
     51005  Main Branch must stay active / cannot be deactivated or deleted
     51006  branch not found

   Requires 01_Create_Schema.sql (security.Users) and 03_Security_RBAC.sql (security.Permissions).
   Idempotent - safe to run repeatedly. SQL Server 2016 SP1+.
   ===================================================================================== */


IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'security.Permissions', N'U') IS NULL
BEGIN
    RAISERROR ('Run 01_Create_Schema.sql and 03_Security_RBAC.sql before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'masterdata') IS NULL
    EXEC (N'CREATE SCHEMA [masterdata] AUTHORIZATION [dbo];');
GO

/* ------------------------------------------------------------------ 1. Table */

IF OBJECT_ID(N'masterdata.Branches', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Branches
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        BranchCode   NVARCHAR(20)      NOT NULL,   -- unique, case-insensitive (database collation)
        BranchName   NVARCHAR(150)     NOT NULL,
        Address      NVARCHAR(500)     NULL,
        IsMainBranch BIT               NOT NULL CONSTRAINT DF_Branches_IsMainBranch DEFAULT (0),
        IsActive     BIT               NOT NULL CONSTRAINT DF_Branches_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_Branches_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,       -- security.Users.Id
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,       -- security.Users.Id
        RowVersion   ROWVERSION        NOT NULL,   -- optimistic concurrency
        CONSTRAINT PK_Branches PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Branches_BranchCode UNIQUE (BranchCode),
        CONSTRAINT CK_Branches_BranchCode_NotBlank CHECK (LEN(LTRIM(RTRIM(BranchCode))) > 0),
        CONSTRAINT CK_Branches_BranchName_NotBlank CHECK (LEN(LTRIM(RTRIM(BranchName))) > 0),
        CONSTRAINT CK_Branches_MainIsActive CHECK (IsMainBranch = 0 OR IsActive = 1),   -- the main branch is always active
        CONSTRAINT FK_Branches_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Branches_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    -- Rule 5: only one active branch can be the Main Branch (filtered unique index).
    CREATE UNIQUE NONCLUSTERED INDEX UX_Branches_ActiveMainBranch
        ON masterdata.Branches (IsMainBranch)
        WHERE IsMainBranch = 1 AND IsActive = 1;

    CREATE NONCLUSTERED INDEX IX_Branches_BranchName ON masterdata.Branches (BranchName);

    PRINT 'Created masterdata.Branches';
END
GO

/* ------------------------------------------------------------------ 2. Procedures */

-- Paged, filtered, sorted list. Returns the page rows plus TotalCount (same value on every row).
CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Search
    @Search        NVARCHAR(150) = NULL,        -- matches Branch Code or Branch Name (contains)
    @IsActive      BIT           = NULL,        -- NULL = all
    @IsMainBranch  BIT           = NULL,        -- NULL = all
    @SortColumn    NVARCHAR(30)  = N'BranchCode', -- BranchCode | BranchName | Address | IsMainBranch | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',      -- ASC | DESC
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'BranchCode', N'BranchName', N'Address', N'IsMainBranch', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'BranchCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT b.Id, b.BranchCode, b.BranchName, b.Address, b.IsMainBranch, b.IsActive,
           b.CreatedAtUtc, b.CreatedBy, b.UpdatedAtUtc, b.UpdatedBy, b.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Branches b
    WHERE (@Search IS NULL OR b.BranchCode LIKE N'%' + @Search + N'%' OR b.BranchName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR b.IsActive = @IsActive)
      AND (@IsMainBranch IS NULL OR b.IsMainBranch = @IsMainBranch)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'BranchCode' THEN b.BranchCode WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN b.Address END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'BranchCode' THEN b.BranchCode WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN b.Address END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'IsMainBranch' THEN CAST(b.IsMainBranch AS INT) WHEN N'IsActive' THEN CAST(b.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'IsMainBranch' THEN CAST(b.IsMainBranch AS INT) WHEN N'IsActive' THEN CAST(b.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END DESC,
        b.BranchCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BranchCode, BranchName, Address, IsMainBranch, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Branches
    WHERE Id = @Id;
END
GO

-- The current active Main Branch (0 or 1 row).
CREATE OR ALTER PROCEDURE masterdata.usp_Branch_GetMain
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Id, BranchCode, BranchName, Address, IsMainBranch, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Branches
    WHERE IsMainBranch = 1 AND IsActive = 1;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Create
    @BranchCode        NVARCHAR(20),
    @BranchName        NVARCHAR(150),
    @Address           NVARCHAR(500) = NULL,
    @IsMainBranch      BIT           = 0,
    @IsActive          BIT           = 1,
    @ReplaceMainBranch BIT           = 0,    -- 1 = the caller confirmed replacing the current Main Branch
    @UserId            INT           = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BranchCode = LTRIM(RTRIM(@BranchCode));
    SET @BranchName = LTRIM(RTRIM(@BranchName));
    SET @Address    = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainBranch = ISNULL(@IsMainBranch, 0);
    SET @IsActive     = ISNULL(@IsActive, 1);

    IF @BranchCode IS NULL OR @BranchCode = N''
        THROW 51000, 'Branch Code is required.', 1;

    IF @BranchName IS NULL OR @BranchName = N''
        THROW 51000, 'Branch Name is required.', 1;

    IF @IsMainBranch = 1 AND @IsActive = 0
        THROW 51005, 'The Main Branch must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE BranchCode = @BranchCode)
        THROW 51001, 'A branch with this Branch Code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainBranch = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Branches WITH (UPDLOCK, HOLDLOCK) WHERE IsMainBranch = 1 AND IsActive = 1);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainBranch = 0
                    THROW 51002, 'Another active branch is already designated as the Main Branch. Confirm to replace it.', 1;

                UPDATE masterdata.Branches
                SET IsMainBranch = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        INSERT INTO masterdata.Branches (BranchCode, BranchName, Address, IsMainBranch, IsActive, CreatedBy)
        VALUES (@BranchCode, @BranchName, @Address, @IsMainBranch, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Update
    @Id                INT,
    @BranchCode        NVARCHAR(20),
    @BranchName        NVARCHAR(150),
    @Address           NVARCHAR(500) = NULL,
    @IsMainBranch      BIT           = 0,
    @IsActive          BIT           = 1,
    @ReplaceMainBranch BIT           = 0,
    @RowVersion        BINARY(8)     = NULL,   -- pass the value read earlier; NULL skips the concurrency check
    @UserId            INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BranchCode = LTRIM(RTRIM(@BranchCode));
    SET @BranchName = LTRIM(RTRIM(@BranchName));
    SET @Address    = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainBranch = ISNULL(@IsMainBranch, 0);
    SET @IsActive     = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id)
        THROW 51006, 'Branch not found.', 1;

    IF @BranchCode IS NULL OR @BranchCode = N''
        THROW 51000, 'Branch Code is required.', 1;

    IF @BranchName IS NULL OR @BranchName = N''
        THROW 51000, 'Branch Name is required.', 1;

    IF @IsMainBranch = 1 AND @IsActive = 0
        THROW 51005, 'The Main Branch must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE BranchCode = @BranchCode AND Id <> @Id)
        THROW 51001, 'A branch with this Branch Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 51004, 'This branch was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainBranch = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Branches WITH (UPDLOCK, HOLDLOCK)
                 WHERE IsMainBranch = 1 AND IsActive = 1 AND Id <> @Id);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainBranch = 0
                    THROW 51002, 'Another active branch is already designated as the Main Branch. Confirm to replace it.', 1;

                UPDATE masterdata.Branches
                SET IsMainBranch = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        UPDATE masterdata.Branches
        SET BranchCode   = @BranchCode,
            BranchName   = @BranchName,
            Address      = @Address,
            IsMainBranch = @IsMainBranch,
            IsActive     = @IsActive,
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy    = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Branch_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id)
        THROW 51006, 'Branch not found.', 1;

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id AND IsMainBranch = 1)
        THROW 51005, 'The Main Branch cannot be deactivated. Designate another branch as the Main Branch first.', 1;

    UPDATE masterdata.Branches
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Physical delete, allowed only when nothing references the branch. The check reads sys.foreign_keys,
-- so every future table with a foreign key to masterdata.Branches (warehouses, stock, transactions...)
-- is covered automatically without changing this procedure.
CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id)
        THROW 51006, 'Branch not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id AND IsMainBranch = 1)
        THROW 51005, 'The Main Branch cannot be deleted. Designate another branch as the Main Branch first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Branches');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 51003, 'This branch cannot be deleted because it is referenced by other records. You may deactivate the branch instead.', 1;

    DELETE FROM masterdata.Branches WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 3. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.branches.view',   N'View branches',   N'Master Data', N'See the Branches / Sites list.',                         100),
        (N'masterdata.branches.create', N'Create branches', N'Master Data', N'Add new branches / sites.',                              110),
        (N'masterdata.branches.edit',   N'Edit branches',   N'Master Data', N'Change branch details and activate / deactivate them.',  120),
        (N'masterdata.branches.delete', N'Delete branches', N'Master Data', N'Delete branches that are not referenced by other records.', 130)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- System roles (Admin) hold every permission; Manager can view.
INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'masterdata.branches.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'masterdata.branches.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 4. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Branches)
BEGIN
    INSERT INTO masterdata.Branches (BranchCode, BranchName, Address, IsMainBranch, IsActive)
    VALUES (N'BR-001', N'Head Office', NULL, 1, 1);
    PRINT 'Seeded the main branch BR-001 Head Office';
END
GO

-- ===== 07: Master Data - Warehouses =====

/* =====================================================================================
   Inventory_Shipment - 07: Master Data - Warehouses   (user story US-MD-002)

   Schema:  masterdata (created by 06)
   Table:   masterdata.Warehouses  (foreign key to masterdata.Branches)
   Procs:   masterdata.usp_Warehouse_Search, usp_Warehouse_Get, usp_Warehouse_GetMain, usp_Warehouse_Lookup,
            usp_Warehouse_Create, usp_Warehouse_Update, usp_Warehouse_SetActive, usp_Warehouse_Delete,
            masterdata.usp_Branch_Lookup (dropdown data for the warehouse form / filter)
   Seeds:   permissions masterdata.warehouses.view / create / edit / delete (module "Master Data"), granted to
            every system role (Admin) and view-only to Manager; a first main warehouse WH-001 "Main Warehouse"
            on the main branch when the table is empty.

   Business rules enforced here (error numbers are read by the API):
     52000  validation (required field / invalid value)
     52001  Warehouse Code already exists
     52002  another active warehouse is already the Main Warehouse (call again with @ReplaceMainWarehouse = 1
            after the user confirms)
     52003  warehouse contains inventory / is referenced by other records - cannot be deleted
     52004  concurrency conflict (RowVersion changed)
     52005  Main Warehouse must stay active / cannot be deactivated or deleted
     52006  warehouse not found
     52007  Branch / Site not found or inactive (a warehouse must be assigned to an active branch)

   Because masterdata.Warehouses references masterdata.Branches, usp_Branch_Delete (06) now refuses to delete
   a branch that has warehouses - no change needed there.

   Requires 06_MasterData_Branches.sql. Idempotent - safe to run repeatedly. SQL Server 2016 SP1+.
   ===================================================================================== */


IF OBJECT_ID(N'masterdata.Branches', N'U') IS NULL OR OBJECT_ID(N'security.Permissions', N'U') IS NULL
BEGIN
    RAISERROR ('Run 06_MasterData_Branches.sql (and the security scripts) before this script.', 16, 1);
    RETURN;
END
GO

/* ------------------------------------------------------------------ 1. Table */

IF OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Warehouses
    (
        Id              INT IDENTITY(1,1) NOT NULL,
        WarehouseCode   NVARCHAR(20)      NOT NULL,   -- unique, case-insensitive (database collation)
        WarehouseName   NVARCHAR(150)     NOT NULL,
        BranchId        INT               NOT NULL,   -- masterdata.Branches.Id
        Address         NVARCHAR(500)     NULL,
        IsMainWarehouse BIT               NOT NULL CONSTRAINT DF_Warehouses_IsMainWarehouse DEFAULT (0),
        IsActive        BIT               NOT NULL CONSTRAINT DF_Warehouses_IsActive DEFAULT (1),
        CreatedAtUtc    DATETIME2(3)      NOT NULL CONSTRAINT DF_Warehouses_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy       INT               NULL,       -- security.Users.Id
        UpdatedAtUtc    DATETIME2(3)      NULL,
        UpdatedBy       INT               NULL,       -- security.Users.Id
        RowVersion      ROWVERSION        NOT NULL,   -- optimistic concurrency
        CONSTRAINT PK_Warehouses PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Warehouses_WarehouseCode UNIQUE (WarehouseCode),
        CONSTRAINT CK_Warehouses_WarehouseCode_NotBlank CHECK (LEN(LTRIM(RTRIM(WarehouseCode))) > 0),
        CONSTRAINT CK_Warehouses_WarehouseName_NotBlank CHECK (LEN(LTRIM(RTRIM(WarehouseName))) > 0),
        CONSTRAINT CK_Warehouses_MainIsActive CHECK (IsMainWarehouse = 0 OR IsActive = 1),   -- the main warehouse is always active
        CONSTRAINT FK_Warehouses_Branches  FOREIGN KEY (BranchId)  REFERENCES masterdata.Branches (Id),   -- no cascade: a branch with warehouses cannot be deleted
        CONSTRAINT FK_Warehouses_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Warehouses_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    -- Rule 6: only one active warehouse can be the Main Warehouse (filtered unique index).
    CREATE UNIQUE NONCLUSTERED INDEX UX_Warehouses_ActiveMainWarehouse
        ON masterdata.Warehouses (IsMainWarehouse)
        WHERE IsMainWarehouse = 1 AND IsActive = 1;

    CREATE NONCLUSTERED INDEX IX_Warehouses_BranchId      ON masterdata.Warehouses (BranchId);
    CREATE NONCLUSTERED INDEX IX_Warehouses_WarehouseName ON masterdata.Warehouses (WarehouseName);

    PRINT 'Created masterdata.Warehouses';
END
GO

/* ------------------------------------------------------------------ 2. Lookups (dropdown data) */

-- Branches for dropdowns. @ActiveOnly = 1 returns active branches only; @IncludeId always includes that branch
-- (so an edit form can still show the currently assigned branch even if it was deactivated).
CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BranchCode, BranchName, IsMainBranch, IsActive
    FROM masterdata.Branches
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY IsMainBranch DESC, BranchName;
END
GO

-- Warehouses for dropdowns (item default warehouse, stock transactions...). Inactive warehouses are excluded
-- unless @ActiveOnly = 0 or they are the @IncludeId.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.IsMainWarehouse, w.IsActive
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE (@ActiveOnly = 0 OR w.IsActive = 1 OR w.Id = @IncludeId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
    ORDER BY w.IsMainWarehouse DESC, w.WarehouseName;
END
GO

/* ------------------------------------------------------------------ 3. Procedures */

-- Paged, filtered, sorted list with the branch joined. TotalCount is repeated on every row.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Search
    @Search          NVARCHAR(150) = NULL,          -- matches Warehouse Code or Warehouse Name (contains)
    @BranchId        INT           = NULL,          -- NULL = all branches
    @IsActive        BIT           = NULL,          -- NULL = all
    @IsMainWarehouse BIT           = NULL,          -- NULL = all
    @SortColumn      NVARCHAR(30)  = N'WarehouseCode', -- WarehouseCode | WarehouseName | BranchName | Address | IsMainWarehouse | IsActive | CreatedAtUtc
    @SortDirection   NVARCHAR(4)   = N'ASC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'WarehouseCode', N'WarehouseName', N'BranchName', N'Address', N'IsMainWarehouse', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'WarehouseCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE (@Search IS NULL OR w.WarehouseCode LIKE N'%' + @Search + N'%' OR w.WarehouseName LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@IsActive IS NULL OR w.IsActive = @IsActive)
      AND (@IsMainWarehouse IS NULL OR w.IsMainWarehouse = @IsMainWarehouse)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'WarehouseCode' THEN w.WarehouseCode WHEN N'WarehouseName' THEN w.WarehouseName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN w.Address END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'WarehouseCode' THEN w.WarehouseCode WHEN N'WarehouseName' THEN w.WarehouseName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN w.Address END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'IsMainWarehouse' THEN CAST(w.IsMainWarehouse AS INT) WHEN N'IsActive' THEN CAST(w.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'IsMainWarehouse' THEN CAST(w.IsMainWarehouse AS INT) WHEN N'IsActive' THEN CAST(w.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN w.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN w.CreatedAtUtc END DESC,
        w.WarehouseCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE w.Id = @Id;
END
GO

-- The current active Main Warehouse (0 or 1 row).
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_GetMain
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE w.IsMainWarehouse = 1 AND w.IsActive = 1;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Create
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,   -- 1 = the caller confirmed replacing the current Main Warehouse
    @UserId               INT           = NULL,
    @NewId                INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @WarehouseCode = LTRIM(RTRIM(@WarehouseCode));
    SET @WarehouseName = LTRIM(RTRIM(@WarehouseName));
    SET @Address       = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainWarehouse = ISNULL(@IsMainWarehouse, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF @WarehouseCode IS NULL OR @WarehouseCode = N''
        THROW 52000, 'Warehouse Code is required.', 1;

    IF @WarehouseName IS NULL OR @WarehouseName = N''
        THROW 52000, 'Warehouse Name is required.', 1;

    IF @BranchId IS NULL
        THROW 52000, 'Branch / Site is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 52007, 'The selected Branch / Site does not exist or is inactive. Select an active branch.', 1;

    IF @IsMainWarehouse = 1 AND @IsActive = 0
        THROW 52005, 'The Main Warehouse must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @WarehouseCode)
        THROW 52001, 'A warehouse with this Warehouse Code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainWarehouse = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Warehouses WITH (UPDLOCK, HOLDLOCK) WHERE IsMainWarehouse = 1 AND IsActive = 1);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainWarehouse = 0
                    THROW 52002, 'Another active warehouse is already designated as the Main Warehouse. Confirm to replace it.', 1;

                UPDATE masterdata.Warehouses
                SET IsMainWarehouse = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive, CreatedBy)
        VALUES (@WarehouseCode, @WarehouseName, @BranchId, @Address, @IsMainWarehouse, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Update
    @Id                   INT,
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,
    @RowVersion           BINARY(8)     = NULL,   -- pass the value read earlier; NULL skips the concurrency check
    @UserId               INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @WarehouseCode = LTRIM(RTRIM(@WarehouseCode));
    SET @WarehouseName = LTRIM(RTRIM(@WarehouseName));
    SET @Address       = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainWarehouse = ISNULL(@IsMainWarehouse, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    DECLARE @CurrentBranchId INT = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @Id);

    IF @CurrentBranchId IS NULL
        THROW 52006, 'Warehouse not found.', 1;

    IF @WarehouseCode IS NULL OR @WarehouseCode = N''
        THROW 52000, 'Warehouse Code is required.', 1;

    IF @WarehouseName IS NULL OR @WarehouseName = N''
        THROW 52000, 'Warehouse Name is required.', 1;

    IF @BranchId IS NULL
        THROW 52000, 'Branch / Site is required.', 1;

    -- Rule 3: a (new) branch assignment must point at an active branch. Keeping the current branch is always allowed.
    IF @BranchId <> @CurrentBranchId AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 52007, 'The selected Branch / Site does not exist or is inactive. Select an active branch.', 1;

    IF @IsMainWarehouse = 1 AND @IsActive = 0
        THROW 52005, 'The Main Warehouse must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @WarehouseCode AND Id <> @Id)
        THROW 52001, 'A warehouse with this Warehouse Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 52004, 'This warehouse was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainWarehouse = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Warehouses WITH (UPDLOCK, HOLDLOCK)
                 WHERE IsMainWarehouse = 1 AND IsActive = 1 AND Id <> @Id);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainWarehouse = 0
                    THROW 52002, 'Another active warehouse is already designated as the Main Warehouse. Confirm to replace it.', 1;

                UPDATE masterdata.Warehouses
                SET IsMainWarehouse = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        UPDATE masterdata.Warehouses
        SET WarehouseCode   = @WarehouseCode,
            WarehouseName   = @WarehouseName,
            BranchId        = @BranchId,
            Address         = @Address,
            IsMainWarehouse = @IsMainWarehouse,
            IsActive        = @IsActive,
            UpdatedAtUtc    = SYSUTCDATETIME(),
            UpdatedBy       = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deactivated. Designate another warehouse as the Main Warehouse first.', 1;

    -- Re-activating a warehouse whose branch is inactive is not allowed (rule 3).
    IF @IsActive = 1 AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                     WHERE w.Id = @Id AND b.IsActive = 1)
        THROW 52007, 'The warehouse cannot be activated because its Branch / Site is inactive.', 1;

    UPDATE masterdata.Warehouses
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Physical delete, allowed only when nothing references the warehouse. The check reads sys.foreign_keys, so
-- every future table with a foreign key to masterdata.Warehouses (stock, movements, transactions, item default
-- warehouse...) is covered automatically without changing this procedure.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deleted. Designate another warehouse as the Main Warehouse first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Warehouses');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 52003, 'This warehouse cannot be deleted because it contains inventory or is referenced by other records. You may deactivate the warehouse instead.', 1;

    DELETE FROM masterdata.Warehouses WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 4. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.warehouses.view',   N'View warehouses',   N'Master Data', N'See the Warehouses list.',                                 140),
        (N'masterdata.warehouses.create', N'Create warehouses', N'Master Data', N'Add new warehouses.',                                      150),
        (N'masterdata.warehouses.edit',   N'Edit warehouses',   N'Master Data', N'Change warehouse details and activate / deactivate them.', 160),
        (N'masterdata.warehouses.delete', N'Delete warehouses', N'Master Data', N'Delete warehouses that are not referenced by other records.', 170)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- System roles (Admin) hold every permission; Manager can view.
INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'masterdata.warehouses.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'masterdata.warehouses.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 5. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses)
BEGIN
    DECLARE @MainBranchId INT = (SELECT TOP (1) Id FROM masterdata.Branches WHERE IsMainBranch = 1 AND IsActive = 1);

    IF @MainBranchId IS NULL
        SET @MainBranchId = (SELECT TOP (1) Id FROM masterdata.Branches WHERE IsActive = 1 ORDER BY Id);

    IF @MainBranchId IS NOT NULL
    BEGIN
        INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive)
        VALUES (N'WH-001', N'Main Warehouse', @MainBranchId, NULL, 1, 1);
        PRINT 'Seeded the main warehouse WH-001 Main Warehouse';
    END
END
GO
=======
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
