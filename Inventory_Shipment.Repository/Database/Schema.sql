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

-- ===== 08: Master Data - Currencies & Exchange Rates =====

/* =====================================================================================
   Inventory_Shipment - 08: Master Data - Currencies & Exchange Rates

   Schema:  masterdata (created if missing). One schema per module - nothing in dbo.
   Tables:  masterdata.Currencies, masterdata.ExchangeRates
   Procs:   masterdata.usp_Currency_Search / _Get / _GetBase / _Lookup / _Create / _Update /
            _SetActive / _Delete,
            masterdata.usp_ExchangeRate_Search / _Get / _GetLatest / _Create / _Update / _Delete
   Func:    masterdata.fn_GetRate (latest rate on or before a date; 1 for the base currency)
   Seeds:   permissions masterdata.currencies.* (sort 180-210) and masterdata.exchangerates.*
            (sort 220-250), module "Master Data"; currencies USD (base) / EUR / INR / CDF when
            the table is empty.

   Conventions:
     - Exactly one ACTIVE currency is the BASE currency (filtered unique index), same pattern
       as the Main Branch. Amounts are stored and reported in the base currency.
     - A rate means: 1 unit of the BASE currency = Rate units of the quoted currency
       (e.g. base USD, CDF rate 2800.000000 -> 1 USD = 2,800 CDF).
     - The base currency never has rate rows - its rate is 1 by definition.
     - RateType: 1 = Official, 2 = NonOfficial (parallel), 3 = Market.
     - One rate per (currency, type, date); a rate stays effective until a newer date exists
       (fn_GetRate takes the latest RateDate <= the asked date).
     - Future transactions must SNAPSHOT the rate they used into their own rows; deleting or
       editing a rate here never rewrites history.

   Business rules enforced here (error numbers are read by the API):
     53000  validation (required field / invalid value / future date)
     53001  Currency Code already exists
     53002  another active currency is already the Base Currency (confirm: @ReplaceBaseCurrency = 1)
     53003  currency is referenced by other records - cannot be deleted (deactivate instead)
     53004  concurrency conflict (RowVersion changed)
     53005  Base Currency protected (must stay active / cannot be demoted, deleted, or given rates)
     53006  currency / exchange rate not found
     53007  a rate for this currency, type and date already exists
     53008  currency is inactive - rates cannot be added for it

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

/* ------------------------------------------------------------------ 1. Tables */

IF OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Currencies
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        CurrencyCode   NVARCHAR(3)       NOT NULL,   -- ISO 4217, stored upper-case (USD, EUR, CDF...)
        CurrencyName   NVARCHAR(100)     NOT NULL,
        Symbol         NVARCHAR(10)      NULL,       -- $, EUR sign, FC ...
        DecimalPlaces  TINYINT           NOT NULL CONSTRAINT DF_Currencies_DecimalPlaces DEFAULT (2),
        IsBaseCurrency BIT               NOT NULL CONSTRAINT DF_Currencies_IsBaseCurrency DEFAULT (0),
        IsActive       BIT               NOT NULL CONSTRAINT DF_Currencies_IsActive DEFAULT (1),
        CreatedAtUtc   DATETIME2(3)      NOT NULL CONSTRAINT DF_Currencies_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT               NULL,       -- security.Users.Id
        UpdatedAtUtc   DATETIME2(3)      NULL,
        UpdatedBy      INT               NULL,       -- security.Users.Id
        RowVersion     ROWVERSION        NOT NULL,   -- optimistic concurrency
        CONSTRAINT PK_Currencies PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Currencies_CurrencyCode UNIQUE (CurrencyCode),
        CONSTRAINT CK_Currencies_CurrencyCode_NotBlank CHECK (LEN(LTRIM(RTRIM(CurrencyCode))) > 0),
        CONSTRAINT CK_Currencies_CurrencyName_NotBlank CHECK (LEN(LTRIM(RTRIM(CurrencyName))) > 0),
        CONSTRAINT CK_Currencies_DecimalPlaces CHECK (DecimalPlaces <= 6),
        CONSTRAINT CK_Currencies_BaseIsActive CHECK (IsBaseCurrency = 0 OR IsActive = 1),  -- the base currency is always active
        CONSTRAINT FK_Currencies_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Currencies_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    -- Only one active currency can be the Base Currency (same pattern as the Main Branch).
    CREATE UNIQUE NONCLUSTERED INDEX UX_Currencies_ActiveBaseCurrency
        ON masterdata.Currencies (IsBaseCurrency)
        WHERE IsBaseCurrency = 1 AND IsActive = 1;

    CREATE NONCLUSTERED INDEX IX_Currencies_CurrencyName ON masterdata.Currencies (CurrencyName);

    PRINT 'Created masterdata.Currencies';
END
GO

IF OBJECT_ID(N'masterdata.ExchangeRates', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.ExchangeRates
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        CurrencyId   INT               NOT NULL,     -- the quoted currency (never the base currency)
        RateType     TINYINT           NOT NULL,     -- 1 = Official, 2 = NonOfficial, 3 = Market
        RateDate     DATE              NOT NULL,     -- effective date (no future dates)
        Rate         DECIMAL(18,6)     NOT NULL,     -- 1 base currency = Rate x this currency
        Notes        NVARCHAR(300)     NULL,         -- e.g. the market source
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_ExchangeRates_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_ExchangeRates PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ExchangeRates_Currency  FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_ExchangeRates_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_ExchangeRates_UpdatedBy FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT CK_ExchangeRates_RateType CHECK (RateType IN (1, 2, 3)),
        CONSTRAINT CK_ExchangeRates_Rate     CHECK (Rate > 0)
    );

    -- One rate per currency + type + day; also the covering index for latest-rate lookups.
    CREATE UNIQUE NONCLUSTERED INDEX UX_ExchangeRates_Currency_Type_Date
        ON masterdata.ExchangeRates (CurrencyId, RateType, RateDate DESC)
        INCLUDE (Rate);

    CREATE NONCLUSTERED INDEX IX_ExchangeRates_RateDate ON masterdata.ExchangeRates (RateDate);

    PRINT 'Created masterdata.ExchangeRates';
END
GO

/* ------------------------------------------------------------------ 2. Function */

-- The rate in force for a currency/type on a date: the latest RateDate <= @AsOfDate.
-- Returns 1 for the base currency and NULL when no rate has been entered yet.
CREATE OR ALTER FUNCTION masterdata.fn_GetRate
(
    @CurrencyId INT,
    @RateType   TINYINT,       -- 1 Official | 2 NonOfficial | 3 Market
    @AsOfDate   DATE
)
RETURNS DECIMAL(18,6)
AS
BEGIN
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        RETURN 1;

    RETURN
    (
        SELECT TOP (1) Rate
        FROM masterdata.ExchangeRates
        WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate <= @AsOfDate
        ORDER BY RateDate DESC
    );
END
GO

/* ------------------------------------------------------------------ 3. Currency procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Search
    @Search         NVARCHAR(100) = NULL,          -- matches Currency Code or Currency Name (contains)
    @IsActive       BIT           = NULL,          -- NULL = all
    @IsBaseCurrency BIT           = NULL,          -- NULL = all
    @SortColumn     NVARCHAR(30)  = N'CurrencyCode', -- CurrencyCode | CurrencyName | DecimalPlaces | IsBaseCurrency | IsActive | CreatedAtUtc
    @SortDirection  NVARCHAR(4)   = N'ASC',
    @PageNumber     INT           = 1,
    @PageSize       INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'CurrencyCode', N'CurrencyName', N'DecimalPlaces', N'IsBaseCurrency', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'CurrencyCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency, c.IsActive,
           c.CreatedAtUtc, c.CreatedBy, c.UpdatedAtUtc, c.UpdatedBy, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Currencies c
    WHERE (@Search IS NULL OR c.CurrencyCode LIKE N'%' + @Search + N'%' OR c.CurrencyName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
      AND (@IsBaseCurrency IS NULL OR c.IsBaseCurrency = @IsBaseCurrency)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'CurrencyCode' THEN c.CurrencyCode WHEN N'CurrencyName' THEN c.CurrencyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'CurrencyCode' THEN c.CurrencyCode WHEN N'CurrencyName' THEN c.CurrencyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DecimalPlaces' THEN CAST(c.DecimalPlaces AS INT)
                             WHEN N'IsBaseCurrency' THEN CAST(c.IsBaseCurrency AS INT)
                             WHEN N'IsActive' THEN CAST(c.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DecimalPlaces' THEN CAST(c.DecimalPlaces AS INT)
                             WHEN N'IsBaseCurrency' THEN CAST(c.IsBaseCurrency AS INT)
                             WHEN N'IsActive' THEN CAST(c.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.CurrencyCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Currencies
    WHERE Id = @Id;
END
GO

-- The current active Base Currency (0 or 1 row).
CREATE OR ALTER PROCEDURE masterdata.usp_Currency_GetBase
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Currencies
    WHERE IsBaseCurrency = 1 AND IsActive = 1;
END
GO

-- Dropdown data. @ActiveOnly = 1 hides inactive currencies; @IncludeId keeps one inactive row
-- visible (the value already saved on the record being edited).
CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive
    FROM masterdata.Currencies
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY IsBaseCurrency DESC, CurrencyCode;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Create
    @CurrencyCode        NVARCHAR(3),
    @CurrencyName        NVARCHAR(100),
    @Symbol              NVARCHAR(10) = NULL,
    @DecimalPlaces       TINYINT      = 2,
    @IsBaseCurrency      BIT          = 0,
    @IsActive            BIT          = 1,
    @ReplaceBaseCurrency BIT          = 0,    -- 1 = the caller confirmed replacing the current Base Currency
    @UserId              INT          = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CurrencyCode  = UPPER(LTRIM(RTRIM(@CurrencyCode)));
    SET @CurrencyName  = LTRIM(RTRIM(@CurrencyName));
    SET @Symbol        = NULLIF(LTRIM(RTRIM(@Symbol)), N'');
    SET @DecimalPlaces = ISNULL(@DecimalPlaces, 2);
    SET @IsBaseCurrency = ISNULL(@IsBaseCurrency, 0);
    SET @IsActive       = ISNULL(@IsActive, 1);

    IF @CurrencyCode IS NULL OR @CurrencyCode = N''
        THROW 53000, 'Currency Code is required.', 1;

    IF LEN(@CurrencyCode) <> 3 OR @CurrencyCode LIKE N'%[^A-Z]%'
        THROW 53000, 'Currency Code must be exactly 3 letters (ISO 4217, e.g. USD).', 1;

    IF @CurrencyName IS NULL OR @CurrencyName = N''
        THROW 53000, 'Currency Name is required.', 1;

    IF @DecimalPlaces > 6
        THROW 53000, 'Decimal Places must be between 0 and 6.', 1;

    IF @IsBaseCurrency = 1 AND @IsActive = 0
        THROW 53005, 'The Base Currency must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE CurrencyCode = @CurrencyCode)
        THROW 53001, 'A currency with this Currency Code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsBaseCurrency = 1
        BEGIN
            DECLARE @CurrentBaseId INT =
                (SELECT TOP (1) Id FROM masterdata.Currencies WITH (UPDLOCK, HOLDLOCK) WHERE IsBaseCurrency = 1 AND IsActive = 1);

            IF @CurrentBaseId IS NOT NULL
            BEGIN
                IF @ReplaceBaseCurrency = 0
                    THROW 53002, 'Another active currency is already designated as the Base Currency. Confirm to replace it.', 1;

                UPDATE masterdata.Currencies
                SET IsBaseCurrency = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentBaseId;
            END
        END

        INSERT INTO masterdata.Currencies (CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive, CreatedBy)
        VALUES (@CurrencyCode, @CurrencyName, @Symbol, @DecimalPlaces, @IsBaseCurrency, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Update
    @Id                  INT,
    @CurrencyCode        NVARCHAR(3),
    @CurrencyName        NVARCHAR(100),
    @Symbol              NVARCHAR(10) = NULL,
    @DecimalPlaces       TINYINT      = 2,
    @IsBaseCurrency      BIT          = 0,
    @IsActive            BIT          = 1,
    @ReplaceBaseCurrency BIT          = 0,
    @RowVersion          BINARY(8)    = NULL,   -- pass the value read earlier; NULL skips the concurrency check
    @UserId              INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CurrencyCode  = UPPER(LTRIM(RTRIM(@CurrencyCode)));
    SET @CurrencyName  = LTRIM(RTRIM(@CurrencyName));
    SET @Symbol        = NULLIF(LTRIM(RTRIM(@Symbol)), N'');
    SET @DecimalPlaces = ISNULL(@DecimalPlaces, 2);
    SET @IsBaseCurrency = ISNULL(@IsBaseCurrency, 0);
    SET @IsActive       = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF @CurrencyCode IS NULL OR @CurrencyCode = N''
        THROW 53000, 'Currency Code is required.', 1;

    IF LEN(@CurrencyCode) <> 3 OR @CurrencyCode LIKE N'%[^A-Z]%'
        THROW 53000, 'Currency Code must be exactly 3 letters (ISO 4217, e.g. USD).', 1;

    IF @CurrencyName IS NULL OR @CurrencyName = N''
        THROW 53000, 'Currency Name is required.', 1;

    IF @DecimalPlaces > 6
        THROW 53000, 'Decimal Places must be between 0 and 6.', 1;

    IF @IsBaseCurrency = 1 AND @IsActive = 0
        THROW 53005, 'The Base Currency must be active.', 1;

    -- The base currency cannot be demoted or deactivated from here; another currency must take
    -- over the base flag first (or in the same call on that other currency with @ReplaceBaseCurrency = 1).
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1 AND IsActive = 1)
       AND (@IsBaseCurrency = 0 OR @IsActive = 0)
        THROW 53005, 'The Base Currency cannot be demoted or deactivated. Designate another currency as the Base Currency first.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE CurrencyCode = @CurrencyCode AND Id <> @Id)
        THROW 53001, 'A currency with this Currency Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 53004, 'This currency was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsBaseCurrency = 1
        BEGIN
            DECLARE @CurrentBaseId INT =
                (SELECT TOP (1) Id FROM masterdata.Currencies WITH (UPDLOCK, HOLDLOCK)
                 WHERE IsBaseCurrency = 1 AND IsActive = 1 AND Id <> @Id);

            IF @CurrentBaseId IS NOT NULL
            BEGIN
                IF @ReplaceBaseCurrency = 0
                    THROW 53002, 'Another active currency is already designated as the Base Currency. Confirm to replace it.', 1;

                UPDATE masterdata.Currencies
                SET IsBaseCurrency = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentBaseId;
            END
        END

        UPDATE masterdata.Currencies
        SET CurrencyCode   = @CurrencyCode,
            CurrencyName   = @CurrencyName,
            Symbol         = @Symbol,
            DecimalPlaces  = @DecimalPlaces,
            IsBaseCurrency = @IsBaseCurrency,
            IsActive       = @IsActive,
            UpdatedAtUtc   = SYSUTCDATETIME(),
            UpdatedBy      = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency cannot be deactivated. Designate another currency as the Base Currency first.', 1;

    UPDATE masterdata.Currencies
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Physical delete, allowed only when nothing references the currency. The check reads
-- sys.foreign_keys, so exchange rates and every future table with a foreign key to
-- masterdata.Currencies (prices, invoices, payments...) are covered automatically.
CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency cannot be deleted. Designate another currency as the Base Currency first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Currencies');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 53003, 'This currency cannot be deleted because it is referenced by other records (e.g. exchange rates). You may deactivate the currency instead.', 1;

    DELETE FROM masterdata.Currencies WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 4. Exchange rate procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Search
    @CurrencyId    INT          = NULL,          -- NULL = all currencies
    @RateType      TINYINT      = NULL,          -- NULL = all types (1 Official | 2 NonOfficial | 3 Market)
    @DateFrom      DATE         = NULL,
    @DateTo        DATE         = NULL,
    @SortColumn    NVARCHAR(30) = N'RateDate',   -- RateDate | CurrencyCode | RateType | Rate | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'DESC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'RateDate', N'CurrencyCode', N'RateType', N'Rate', N'CreatedAtUtc')
        SET @SortColumn = N'RateDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT er.Id, er.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           er.RateType, er.RateDate, er.Rate, er.Notes,
           er.CreatedAtUtc, er.CreatedBy, er.UpdatedAtUtc, er.UpdatedBy, er.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.ExchangeRates er
    INNER JOIN masterdata.Currencies c ON c.Id = er.CurrencyId
    WHERE (@CurrencyId IS NULL OR er.CurrencyId = @CurrencyId)
      AND (@RateType   IS NULL OR er.RateType = @RateType)
      AND (@DateFrom   IS NULL OR er.RateDate >= @DateFrom)
      AND (@DateTo     IS NULL OR er.RateDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'RateDate' THEN er.RateDate END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'RateDate' THEN er.RateDate END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CurrencyCode' THEN c.CurrencyCode END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CurrencyCode' THEN c.CurrencyCode END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'RateType' THEN CAST(er.RateType AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'RateType' THEN CAST(er.RateType AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Rate' THEN er.Rate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Rate' THEN er.Rate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN er.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN er.CreatedAtUtc END DESC,
        er.RateDate DESC, c.CurrencyCode ASC, er.RateType ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT er.Id, er.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           er.RateType, er.RateDate, er.Rate, er.Notes,
           er.CreatedAtUtc, er.CreatedBy, er.UpdatedAtUtc, er.UpdatedBy, er.RowVersion
    FROM masterdata.ExchangeRates er
    INNER JOIN masterdata.Currencies c ON c.Id = er.CurrencyId
    WHERE er.Id = @Id;
END
GO

-- The rate in force per type (up to 3 rows: Official / NonOfficial / Market) for one currency,
-- as of a date (default: today, UTC).
CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_GetLatest
    @CurrencyId INT,
    @AsOfDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);

    SELECT x.Id, x.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           x.RateType, x.RateDate, x.Rate, x.Notes,
           x.CreatedAtUtc, x.CreatedBy, x.UpdatedAtUtc, x.UpdatedBy, x.RowVersion
    FROM
    (
        SELECT er.*, ROW_NUMBER() OVER (PARTITION BY er.RateType ORDER BY er.RateDate DESC) AS rn
        FROM masterdata.ExchangeRates er
        WHERE er.CurrencyId = @CurrencyId AND er.RateDate <= @AsOfDate
    ) x
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.rn = 1
    ORDER BY x.RateType;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Create
    @CurrencyId INT,
    @RateType   TINYINT,               -- 1 Official | 2 NonOfficial | 3 Market
    @RateDate   DATE,
    @Rate       DECIMAL(18,6),
    @Notes      NVARCHAR(300) = NULL,
    @UserId     INT           = NULL,
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF @CurrencyId IS NULL
        THROW 53000, 'Currency is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency always has a rate of 1 - exchange rates are entered for the other currencies.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 53008, 'This currency is inactive. Activate it before adding exchange rates.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3)
        THROW 53000, 'Rate Type must be Official, Non-official or Market.', 1;

    IF @RateDate IS NULL
        THROW 53000, 'Rate Date is required.', 1;

    IF @RateDate > CAST(SYSUTCDATETIME() AS DATE)
        THROW 53000, 'Rate Date cannot be in the future.', 1;

    IF @Rate IS NULL OR @Rate <= 0
        THROW 53000, 'Rate must be greater than zero.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ExchangeRates
               WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate = @RateDate)
        THROW 53007, 'A rate for this currency, rate type and date already exists. Edit that rate instead.', 1;

    INSERT INTO masterdata.ExchangeRates (CurrencyId, RateType, RateDate, Rate, Notes, CreatedBy)
    VALUES (@CurrencyId, @RateType, @RateDate, @Rate, @Notes, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Update
    @Id         INT,
    @CurrencyId INT,
    @RateType   TINYINT,
    @RateDate   DATE,
    @Rate       DECIMAL(18,6),
    @Notes      NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,   -- NULL skips the concurrency check
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id)
        THROW 53006, 'Exchange rate not found.', 1;

    IF @CurrencyId IS NULL
        THROW 53000, 'Currency is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency always has a rate of 1 - exchange rates are entered for the other currencies.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3)
        THROW 53000, 'Rate Type must be Official, Non-official or Market.', 1;

    IF @RateDate IS NULL
        THROW 53000, 'Rate Date is required.', 1;

    IF @RateDate > CAST(SYSUTCDATETIME() AS DATE)
        THROW 53000, 'Rate Date cannot be in the future.', 1;

    IF @Rate IS NULL OR @Rate <= 0
        THROW 53000, 'Rate must be greater than zero.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ExchangeRates
               WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate = @RateDate AND Id <> @Id)
        THROW 53007, 'A rate for this currency, rate type and date already exists. Edit that rate instead.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 53004, 'This exchange rate was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.ExchangeRates
    SET CurrencyId   = @CurrencyId,
        RateType     = @RateType,
        RateDate     = @RateDate,
        Rate         = @Rate,
        Notes        = @Notes,
        UpdatedAtUtc = SYSUTCDATETIME(),
        UpdatedBy    = @UserId
    WHERE Id = @Id;
END
GO

-- Rates are reference data: transactions snapshot the rate they used, so deleting a wrongly
-- entered rate is safe and allowed.
CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id)
        THROW 53006, 'Exchange rate not found.', 1;

    DELETE FROM masterdata.ExchangeRates WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 5. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.currencies.view',      N'View currencies',       N'Master Data', N'See the Currencies list.',                                        180),
        (N'masterdata.currencies.create',    N'Create currencies',     N'Master Data', N'Add new currencies.',                                             190),
        (N'masterdata.currencies.edit',      N'Edit currencies',       N'Master Data', N'Change currency details, the base currency and active status.',   200),
        (N'masterdata.currencies.delete',    N'Delete currencies',     N'Master Data', N'Delete currencies that are not referenced by other records.',     210),
        (N'masterdata.exchangerates.view',   N'View exchange rates',   N'Master Data', N'See the Exchange Rates page and the latest rates.',               220),
        (N'masterdata.exchangerates.create', N'Create exchange rates', N'Master Data', N'Enter official, non-official and market rates.',                  230),
        (N'masterdata.exchangerates.edit',   N'Edit exchange rates',   N'Master Data', N'Correct entered rates.',                                          240),
        (N'masterdata.exchangerates.delete', N'Delete exchange rates', N'Master Data', N'Remove wrongly entered rates.',                                   250)
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
WHERE (p.Code LIKE N'masterdata.currencies.%' OR p.Code LIKE N'masterdata.exchangerates.%')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'masterdata.currencies.view', N'masterdata.exchangerates.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 6. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies)
BEGIN
    INSERT INTO masterdata.Currencies (CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive)
    VALUES (N'USD', N'US Dollar',        N'$',  2, 1, 1),
           (N'EUR', N'Euro',             N'€',  2, 0, 1),
           (N'INR', N'Indian Rupee',     N'₹',  2, 0, 1),
           (N'CDF', N'Congolese Franc',  N'FC', 2, 0, 1);
    PRINT 'Seeded currencies: USD (base), EUR, INR, CDF - deactivate the ones you do not use.';
END
GO

-- ===== 09: Master Data - Item Families =====

/* =====================================================================================
   Inventory_Shipment - 09: Master Data - Item Families   (user story US-MD-004)

   Schema:  masterdata (created if missing). One schema per module - nothing in dbo.
   Table:   masterdata.ItemFamilies (self-referencing tree, UNLIMITED depth)
   Procs:   masterdata.usp_ItemFamily_Tree / _Get / _Lookup / _NextChildCode / _Create /
            _Update / _SetActive / _Delete
   Func:    masterdata.fn_ItemFamily_Subtree (a family and every descendant; loop-based,
            so there is NO recursion depth limit)
   Seeds:   permissions masterdata.itemfamilies.view / create / edit / delete (sort 260-290,
            module "Master Data"); a small starter tree when the table is empty.

   Design decisions (agreed):
     - ONE tree replaces the separate Sub Groups / Categories pages: a sub group is simply
       a child family. Items (next story) may attach to a family at ANY level.
     - Depth is UNLIMITED - all hierarchy operations are iterative (WHILE loops), never
       recursive CTEs, so no MAXRECURSION ceiling applies.
     - Codes are auto-SUGGESTED from the parent (FAM-002 child -> FAM-002-01) but freely
       editable, globally unique, and NEVER renamed when a family is moved.
     - A family can be active only when its parent is active. Deactivating a family
       deactivates its whole subtree; activating touches only the family itself.
     - Level (1 = root) is stored and recomputed by the procedures on create/move.

   Business rules enforced here (error numbers are read by the API):
     54000  validation (required field / invalid value)
     54001  Family Code already exists
     54002  a family with this name already exists under the same parent
     54003  family is referenced by other records (items...) - cannot be deleted
     54004  concurrency conflict (RowVersion changed)
     54005  family has child families - cannot be deleted
     54006  family / parent family not found
     54007  circular hierarchy (the parent is the family itself or one of its descendants)
     54008  parent family is inactive (cannot create/activate an active child under it)

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

IF OBJECT_ID(N'masterdata.ItemFamilies', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.ItemFamilies
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        ParentId     INT               NULL,        -- NULL = root family
        FamilyCode   NVARCHAR(50)      NOT NULL,    -- unique, stable (not renamed on move)
        FamilyName   NVARCHAR(150)     NOT NULL,
        Description  NVARCHAR(500)     NULL,
        [Level]      INT               NOT NULL CONSTRAINT DF_ItemFamilies_Level DEFAULT (1),  -- 1 = root, maintained by the procs
        IsActive     BIT               NOT NULL CONSTRAINT DF_ItemFamilies_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_ItemFamilies_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,        -- security.Users.Id
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_ItemFamilies PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ItemFamilies_FamilyCode UNIQUE (FamilyCode),
        CONSTRAINT CK_ItemFamilies_FamilyCode_NotBlank CHECK (LEN(LTRIM(RTRIM(FamilyCode))) > 0),
        CONSTRAINT CK_ItemFamilies_FamilyName_NotBlank CHECK (LEN(LTRIM(RTRIM(FamilyName))) > 0),
        CONSTRAINT CK_ItemFamilies_Level CHECK ([Level] >= 1),
        CONSTRAINT CK_ItemFamilies_NotOwnParent CHECK (ParentId IS NULL OR ParentId <> Id),
        CONSTRAINT FK_ItemFamilies_Parent    FOREIGN KEY (ParentId)  REFERENCES masterdata.ItemFamilies (Id),
        CONSTRAINT FK_ItemFamilies_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_ItemFamilies_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    -- Sibling names must differ (NULL parents compare equal in a unique index, so root names are unique too).
    CREATE UNIQUE NONCLUSTERED INDEX UX_ItemFamilies_Parent_FamilyName
        ON masterdata.ItemFamilies (ParentId, FamilyName);

    CREATE NONCLUSTERED INDEX IX_ItemFamilies_ParentId ON masterdata.ItemFamilies (ParentId);

    PRINT 'Created masterdata.ItemFamilies';
END
GO

/* ------------------------------------------------------------------ 2. Subtree function (loop-based, no depth limit) */

-- A family plus every descendant. Iterative, so it works at ANY depth.
CREATE OR ALTER FUNCTION masterdata.fn_ItemFamily_Subtree (@Id INT)
RETURNS @Result TABLE (Id INT PRIMARY KEY, ParentId INT NULL, [Level] INT NOT NULL)
AS
BEGIN
    INSERT INTO @Result (Id, ParentId, [Level])
    SELECT Id, ParentId, [Level] FROM masterdata.ItemFamilies WHERE Id = @Id;

    WHILE @@ROWCOUNT > 0
    BEGIN
        INSERT INTO @Result (Id, ParentId, [Level])
        SELECT f.Id, f.ParentId, f.[Level]
        FROM masterdata.ItemFamilies f
        INNER JOIN @Result r ON r.Id = f.ParentId
        WHERE NOT EXISTS (SELECT 1 FROM @Result x WHERE x.Id = f.Id);
    END

    RETURN;
END
GO

/* ------------------------------------------------------------------ 3. Procedures */

-- The WHOLE tree in one flat result set (the page builds the hierarchy client-side; the
-- table is small, so there is no server paging on purpose - paging cannot work on a tree).
CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_Tree
AS
BEGIN
    SET NOCOUNT ON;

    SELECT f.Id, f.ParentId, f.FamilyCode, f.FamilyName, f.Description, f.[Level], f.IsActive,
           f.CreatedAtUtc, f.CreatedBy, f.UpdatedAtUtc, f.UpdatedBy, f.RowVersion,
           ChildCount = (SELECT COUNT(*) FROM masterdata.ItemFamilies c WHERE c.ParentId = f.Id)
    FROM masterdata.ItemFamilies f
    ORDER BY f.[Level], f.FamilyCode;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.ParentId, f.FamilyCode, f.FamilyName, f.Description, f.[Level], f.IsActive,
           f.CreatedAtUtc, f.CreatedBy, f.UpdatedAtUtc, f.UpdatedBy, f.RowVersion,
           ChildCount = (SELECT COUNT(*) FROM masterdata.ItemFamilies c WHERE c.ParentId = f.Id)
    FROM masterdata.ItemFamilies f
    WHERE f.Id = @Id;
END
GO

-- Dropdown data for other pages (e.g. the item definition later). Flat list; the client
-- indents by Level / builds paths from ParentId. @ActiveOnly = 1 hides inactive families;
-- @IncludeId keeps one inactive row visible (the value already saved on the record being edited).
CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ParentId, FamilyCode, FamilyName, [Level], IsActive
    FROM masterdata.ItemFamilies
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY [Level], FamilyCode;
END
GO

-- Suggested code for a new family: parent's code + '-' + 2-digit sequence (FAM-002 -> FAM-002-01);
-- roots get FAM-### . Only a suggestion - the user may edit it; uniqueness is enforced on save.
CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_NextChildCode
    @ParentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Prefix NVARCHAR(60), @Seq INT = 1, @Digits INT, @Code NVARCHAR(60);

    IF @ParentId IS NULL
    BEGIN
        SET @Prefix = N'FAM-';
        SET @Digits = 3;
    END
    ELSE
    BEGIN
        SELECT @Prefix = FamilyCode + N'-' FROM masterdata.ItemFamilies WHERE Id = @ParentId;
        IF @Prefix IS NULL
            THROW 54006, 'Parent family not found.', 1;
        SET @Digits = 2;
    END

    SET @Code = @Prefix + RIGHT(REPLICATE(N'0', @Digits) + CAST(@Seq AS NVARCHAR(10)), @Digits);
    WHILE EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE FamilyCode = @Code) AND @Seq < 100000
    BEGIN
        SET @Seq += 1;
        SET @Code = @Prefix + RIGHT(REPLICATE(N'0', @Digits) + CAST(@Seq AS NVARCHAR(10)), @Digits);
    END

    SELECT SuggestedCode = LEFT(@Code, 50);
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_Create
    @FamilyCode  NVARCHAR(50),
    @FamilyName  NVARCHAR(150),
    @ParentId    INT           = NULL,
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @FamilyCode  = LTRIM(RTRIM(@FamilyCode));
    SET @FamilyName  = LTRIM(RTRIM(@FamilyName));
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive    = ISNULL(@IsActive, 1);

    IF @FamilyCode IS NULL OR @FamilyCode = N''
        THROW 54000, 'Family Code is required.', 1;

    IF @FamilyName IS NULL OR @FamilyName = N''
        THROW 54000, 'Family Name is required.', 1;

    DECLARE @ParentLevel INT = 0, @ParentActive BIT = 1;

    IF @ParentId IS NOT NULL
    BEGIN
        SELECT @ParentLevel = [Level], @ParentActive = IsActive
        FROM masterdata.ItemFamilies WHERE Id = @ParentId;

        IF @ParentLevel IS NULL OR @ParentLevel = 0
            THROW 54006, 'Parent family not found.', 1;

        IF @IsActive = 1 AND @ParentActive = 0
            THROW 54008, 'The parent family is inactive. Activate it first, or create this family as inactive.', 1;
    END

    IF EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE FamilyCode = @FamilyCode)
        THROW 54001, 'A family with this Family Code already exists.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ItemFamilies
               WHERE FamilyName = @FamilyName
                 AND ((ParentId IS NULL AND @ParentId IS NULL) OR ParentId = @ParentId))
        THROW 54002, 'A family with this name already exists under the same parent.', 1;

    INSERT INTO masterdata.ItemFamilies (ParentId, FamilyCode, FamilyName, Description, [Level], IsActive, CreatedBy)
    VALUES (@ParentId, @FamilyCode, @FamilyName, @Description, @ParentLevel + 1, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_Update
    @Id          INT,
    @FamilyCode  NVARCHAR(50),
    @FamilyName  NVARCHAR(150),
    @ParentId    INT           = NULL,
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,   -- NULL skips the concurrency check
    @UserId      INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @FamilyCode  = LTRIM(RTRIM(@FamilyCode));
    SET @FamilyName  = LTRIM(RTRIM(@FamilyName));
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive    = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @Id)
        THROW 54006, 'Item family not found.', 1;

    IF @FamilyCode IS NULL OR @FamilyCode = N''
        THROW 54000, 'Family Code is required.', 1;

    IF @FamilyName IS NULL OR @FamilyName = N''
        THROW 54000, 'Family Name is required.', 1;

    IF @ParentId = @Id
        THROW 54007, 'A family cannot be its own parent.', 1;

    DECLARE @ParentLevel INT = 0, @ParentActive BIT = 1;

    IF @ParentId IS NOT NULL
    BEGIN
        SELECT @ParentLevel = [Level], @ParentActive = IsActive
        FROM masterdata.ItemFamilies WHERE Id = @ParentId;

        IF @ParentLevel IS NULL OR @ParentLevel = 0
            THROW 54006, 'Parent family not found.', 1;

        -- Circular check: climb from the new parent to the root; meeting @Id means the new
        -- parent is a descendant of the family being moved. Iterative - no depth limit.
        DECLARE @Cursor INT = @ParentId;
        WHILE @Cursor IS NOT NULL
        BEGIN
            IF @Cursor = @Id
                THROW 54007, 'This would create a circular hierarchy: the selected parent is a descendant of this family.', 1;
            SELECT @Cursor = ParentId FROM masterdata.ItemFamilies WHERE Id = @Cursor;
        END

        IF @IsActive = 1 AND @ParentActive = 0
            THROW 54008, 'The parent family is inactive. Activate it first, or make this family inactive.', 1;
    END

    IF EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE FamilyCode = @FamilyCode AND Id <> @Id)
        THROW 54001, 'A family with this Family Code already exists.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ItemFamilies
               WHERE FamilyName = @FamilyName AND Id <> @Id
                 AND ((ParentId IS NULL AND @ParentId IS NULL) OR ParentId = @ParentId))
        THROW 54002, 'A family with this name already exists under the same parent.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 54004, 'This family was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.ItemFamilies
        SET FamilyCode   = @FamilyCode,
            FamilyName   = @FamilyName,
            ParentId     = @ParentId,
            Description  = @Description,
            [Level]      = @ParentLevel + 1,
            IsActive     = @IsActive,
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy    = @UserId
        WHERE Id = @Id;

        -- Re-level the whole subtree after a possible move (iterative, level by level).
        DECLARE @Frontier TABLE (Id INT PRIMARY KEY);
        DECLARE @Next     TABLE (Id INT PRIMARY KEY);
        DECLARE @ChildLevel INT = @ParentLevel + 2;

        INSERT INTO @Frontier (Id) SELECT Id FROM masterdata.ItemFamilies WHERE ParentId = @Id;

        WHILE EXISTS (SELECT 1 FROM @Frontier)
        BEGIN
            UPDATE f SET [Level] = @ChildLevel
            FROM masterdata.ItemFamilies f
            INNER JOIN @Frontier fr ON fr.Id = f.Id;

            DELETE FROM @Next;
            INSERT INTO @Next (Id)
            SELECT c.Id FROM masterdata.ItemFamilies c INNER JOIN @Frontier fr ON fr.Id = c.ParentId;

            DELETE FROM @Frontier;
            INSERT INTO @Frontier (Id) SELECT Id FROM @Next;
            SET @ChildLevel += 1;
        END

        -- Deactivating cascades to the whole subtree (children may not outlive an inactive parent).
        IF @IsActive = 0
        BEGIN
            UPDATE f
            SET IsActive = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            FROM masterdata.ItemFamilies f
            INNER JOIN masterdata.fn_ItemFamily_Subtree(@Id) s ON s.Id = f.Id
            WHERE f.IsActive = 1 AND f.Id <> @Id;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @Id)
        THROW 54006, 'Item family not found.', 1;

    IF @IsActive = 1 AND EXISTS (SELECT 1 FROM masterdata.ItemFamilies c
                                 INNER JOIN masterdata.ItemFamilies p ON p.Id = c.ParentId
                                 WHERE c.Id = @Id AND p.IsActive = 0)
        THROW 54008, 'The parent family is inactive. Activate the parent first.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsActive = 1
        BEGIN
            UPDATE masterdata.ItemFamilies
            SET IsActive = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id AND IsActive = 0;
        END
        ELSE
        BEGIN
            -- Deactivate the family AND its whole subtree.
            UPDATE f
            SET IsActive = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            FROM masterdata.ItemFamilies f
            INNER JOIN masterdata.fn_ItemFamily_Subtree(@Id) s ON s.Id = f.Id
            WHERE f.IsActive = 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Physical delete: only leaves (no children) that nothing references. The reference check
-- reads sys.foreign_keys EXCLUDING the tree's own self-reference (children are reported as
-- 54005 with their own message), so future tables (items...) are covered automatically.
CREATE OR ALTER PROCEDURE masterdata.usp_ItemFamily_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @Id)
        THROW 54006, 'Item family not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE ParentId = @Id)
        THROW 54005, 'This family cannot be deleted because it contains child families. Delete or move the children first, or deactivate the family instead.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.ItemFamilies')
      AND fk.parent_object_id   <> OBJECT_ID(N'masterdata.ItemFamilies');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 54003, 'This family cannot be deleted because it is assigned to existing items or other records. You may deactivate it instead.', 1;

    DELETE FROM masterdata.ItemFamilies WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 4. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.itemfamilies.view',   N'View item families',   N'Master Data', N'See the Item Families tree.',                                          260),
        (N'masterdata.itemfamilies.create', N'Create item families', N'Master Data', N'Add root and child families.',                                         270),
        (N'masterdata.itemfamilies.edit',   N'Edit item families',   N'Master Data', N'Change family details, move families and activate / deactivate them.', 280),
        (N'masterdata.itemfamilies.delete', N'Delete item families', N'Master Data', N'Delete families without children that are not assigned to items.',     290)
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
WHERE p.Code LIKE N'masterdata.itemfamilies.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'masterdata.itemfamilies.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 5. Seed (starter tree, only when empty) */

IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies)
BEGIN
    DECLARE @Moto INT, @Elec INT;

    INSERT INTO masterdata.ItemFamilies (ParentId, FamilyCode, FamilyName, Description, [Level], IsActive)
    VALUES (NULL, N'FAM-001', N'Motorcycles', N'All motorcycle related items and parts', 1, 1);
    SET @Moto = SCOPE_IDENTITY();

    INSERT INTO masterdata.ItemFamilies (ParentId, FamilyCode, FamilyName, Description, [Level], IsActive)
    VALUES (@Moto, N'FAM-001-01', N'Engine Parts',       N'Engine and its related components',      2, 1),
           (@Moto, N'FAM-001-02', N'Transmission Parts', N'Transmission and clutch components',     2, 1);

    INSERT INTO masterdata.ItemFamilies (ParentId, FamilyCode, FamilyName, Description, [Level], IsActive)
    VALUES (@Moto, N'FAM-001-03', N'Electricals', N'Electrical and electronic parts', 2, 1);
    SET @Elec = SCOPE_IDENTITY();

    INSERT INTO masterdata.ItemFamilies (ParentId, FamilyCode, FamilyName, Description, [Level], IsActive)
    VALUES (@Elec, N'FAM-001-03-01', N'Battery',  N'All types of batteries',   3, 1),
           (@Elec, N'FAM-001-03-02', N'Lighting', N'Lighting and indicators',  3, 1);

    INSERT INTO masterdata.ItemFamilies (ParentId, FamilyCode, FamilyName, Description, [Level], IsActive)
    VALUES (NULL, N'FAM-002', N'Scooters',          N'All scooter related items and parts',      1, 1),
           (NULL, N'FAM-003', N'Maintenance Items', N'Oils, lubricants and maintenance items',   1, 1),
           (NULL, N'FAM-004', N'Accessories',       N'Vehicle accessories and add-ons',          1, 1);

    PRINT 'Seeded a starter item family tree (edit or delete it freely).';
END
GO

-- ===== 10: Master Data - Brands =====

/* =====================================================================================
   Inventory_Shipment - 10: Master Data - Brands

   Schema:  masterdata. Table: masterdata.Brands (flat lookup, Branch pattern - no "main").
   Procs:   masterdata.usp_Brand_Search / _Get / _Lookup / _Create / _Update / _SetActive / _Delete
   Seeds:   permissions masterdata.brands.view / create / edit / delete (sort 300-330,
            module "Master Data"); brand BRD-001 TVS when the table is empty.
   Used by: the Items page dropdown (usp_Brand_Lookup).

   Business rules (error numbers read by the API):
     55000 validation   55001 Brand Code already exists   55003 referenced - cannot delete
     55004 concurrency (RowVersion)   55006 brand not found

   Requires 01 + 03. Idempotent. SQL Server 2016 SP1+.
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

IF OBJECT_ID(N'masterdata.Brands', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Brands
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        BrandCode    NVARCHAR(20)      NOT NULL,
        BrandName    NVARCHAR(150)     NOT NULL,
        Description  NVARCHAR(500)     NULL,
        IsActive     BIT               NOT NULL CONSTRAINT DF_Brands_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_Brands_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_Brands PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Brands_BrandCode UNIQUE (BrandCode),
        CONSTRAINT CK_Brands_BrandCode_NotBlank CHECK (LEN(LTRIM(RTRIM(BrandCode))) > 0),
        CONSTRAINT CK_Brands_BrandName_NotBlank CHECK (LEN(LTRIM(RTRIM(BrandName))) > 0),
        CONSTRAINT FK_Brands_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Brands_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    CREATE NONCLUSTERED INDEX IX_Brands_BrandName ON masterdata.Brands (BrandName);

    PRINT 'Created masterdata.Brands';
END
GO

/* ------------------------------------------------------------------ 2. Procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_Brand_Search
    @Search        NVARCHAR(150) = NULL,        -- matches Brand Code or Brand Name (contains)
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'BrandCode', -- BrandCode | BrandName | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'BrandCode', N'BrandName', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'BrandCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT b.Id, b.BrandCode, b.BrandName, b.Description, b.IsActive,
           b.CreatedAtUtc, b.CreatedBy, b.UpdatedAtUtc, b.UpdatedBy, b.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Brands b
    WHERE (@Search IS NULL OR b.BrandCode LIKE N'%' + @Search + N'%' OR b.BrandName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR b.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'BrandCode' THEN b.BrandCode WHEN N'BrandName' THEN b.BrandName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'BrandCode' THEN b.BrandCode WHEN N'BrandName' THEN b.BrandName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(b.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(b.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END DESC,
        b.BrandCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Brand_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BrandCode, BrandName, Description, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Brands
    WHERE Id = @Id;
END
GO

-- Dropdown data for the Items page. @IncludeId keeps an inactive saved value visible when editing.
CREATE OR ALTER PROCEDURE masterdata.usp_Brand_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BrandCode, BrandName, IsActive
    FROM masterdata.Brands
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY BrandName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Brand_Create
    @BrandCode   NVARCHAR(20),
    @BrandName   NVARCHAR(150),
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @BrandCode   = LTRIM(RTRIM(@BrandCode));
    SET @BrandName   = LTRIM(RTRIM(@BrandName));
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive    = ISNULL(@IsActive, 1);

    IF @BrandCode IS NULL OR @BrandCode = N''
        THROW 55000, 'Brand Code is required.', 1;

    IF @BrandName IS NULL OR @BrandName = N''
        THROW 55000, 'Brand Name is required.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Brands WHERE BrandCode = @BrandCode)
        THROW 55001, 'A brand with this Brand Code already exists.', 1;

    INSERT INTO masterdata.Brands (BrandCode, BrandName, Description, IsActive, CreatedBy)
    VALUES (@BrandCode, @BrandName, @Description, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Brand_Update
    @Id          INT,
    @BrandCode   NVARCHAR(20),
    @BrandName   NVARCHAR(150),
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @BrandCode   = LTRIM(RTRIM(@BrandCode));
    SET @BrandName   = LTRIM(RTRIM(@BrandName));
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive    = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id)
        THROW 55006, 'Brand not found.', 1;

    IF @BrandCode IS NULL OR @BrandCode = N''
        THROW 55000, 'Brand Code is required.', 1;

    IF @BrandName IS NULL OR @BrandName = N''
        THROW 55000, 'Brand Name is required.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Brands WHERE BrandCode = @BrandCode AND Id <> @Id)
        THROW 55001, 'A brand with this Brand Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 55004, 'This brand was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.Brands
    SET BrandCode    = @BrandCode,
        BrandName    = @BrandName,
        Description  = @Description,
        IsActive     = @IsActive,
        UpdatedAtUtc = SYSUTCDATETIME(),
        UpdatedBy    = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Brand_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id)
        THROW 55006, 'Brand not found.', 1;

    UPDATE masterdata.Brands
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Physical delete only when nothing references the brand (sys.foreign_keys covers future tables, e.g. items).
CREATE OR ALTER PROCEDURE masterdata.usp_Brand_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id)
        THROW 55006, 'Brand not found.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Brands');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 55003, 'This brand cannot be deleted because it is assigned to existing items or other records. You may deactivate it instead.', 1;

    DELETE FROM masterdata.Brands WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 3. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.brands.view',   N'View brands',   N'Master Data', N'See the Brands list.',                                    300),
        (N'masterdata.brands.create', N'Create brands', N'Master Data', N'Add new brands.',                                         310),
        (N'masterdata.brands.edit',   N'Edit brands',   N'Master Data', N'Change brand details and activate / deactivate them.',    320),
        (N'masterdata.brands.delete', N'Delete brands', N'Master Data', N'Delete brands that are not assigned to items.',           330)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'masterdata.brands.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'masterdata.brands.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 4. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Brands)
BEGIN
    INSERT INTO masterdata.Brands (BrandCode, BrandName, Description, IsActive)
    VALUES (N'BRD-001', N'TVS', N'TVS Motor Company', 1);
    PRINT 'Seeded brand BRD-001 TVS';
END
GO

-- ===== 11: Unit Types + Item Definition =====

/* =====================================================================================
   Inventory_Shipment - 11: Unit Types (masterdata) + Item Definition (inventory)
   US-INV-001 / US-INV-002

   New schema: inventory (Items, ItemUnits, ItemFiles). Unit Types are an editable master
   list (masterdata.UnitTypes) seeded with PC / Box / Pallet / Container as dummy data.

   Conventions:
     - Quantities are whole pieces (INT). Packing Formula = how many BASE units one unit
       holds (base unit formula = 1). Exactly ONE base unit per item (filtered unique index).
     - Barcode is unique across the whole system (nullable); SKU is required and unique
       within the item.
     - BIVAC is a yes/no flag on the item only (documents come later in the shipment module).
     - On Hand / costs are placeholders (0 / NULL) until the stock & purchase modules exist.
     - Item image + attachments are stored in the database (inventory.ItemFiles); the API
       caps upload size.

   Error numbers (read by the API):
     Unit Types: 57000 validation, 57001 duplicate name, 57003 referenced, 57004 concurrency,
                 57006 not found
     Items:      56000 validation, 56001 duplicate Item Code, 56002 duplicate Barcode,
                 56003 referenced (delete), 56004 concurrency, 56005 base-unit rule,
                 56006 not found, 56007 duplicate SKU within the item,
                 56008 related master data missing/inactive (brand, family, warehouse, unit type)

   Requires 01 + 03 + 06 (Branches) + 07 (Warehouses) + 09 (Item Families) + 10 (Brands).
   Idempotent - safe to run repeatedly. SQL Server 2016 SP1+.
   ===================================================================================== */

IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'security.Permissions', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.ItemFamilies', N'U') IS NULL OR OBJECT_ID(N'masterdata.Brands', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 01, 03, 06, 07, 09 and 10 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'inventory') IS NULL
    EXEC (N'CREATE SCHEMA [inventory] AUTHORIZATION [dbo];');
GO

/* ================================================================== A. UNIT TYPES (masterdata) */

IF OBJECT_ID(N'masterdata.UnitTypes', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.UnitTypes
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        UnitTypeName NVARCHAR(50)      NOT NULL,
        IsActive     BIT               NOT NULL CONSTRAINT DF_UnitTypes_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_UnitTypes_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_UnitTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_UnitTypes_UnitTypeName UNIQUE (UnitTypeName),
        CONSTRAINT CK_UnitTypes_Name_NotBlank CHECK (LEN(LTRIM(RTRIM(UnitTypeName))) > 0),
        CONSTRAINT FK_UnitTypes_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_UnitTypes_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.UnitTypes';
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Search
    @Search        NVARCHAR(50) = NULL,
    @IsActive      BIT          = NULL,
    @SortColumn    NVARCHAR(30) = N'UnitTypeName',  -- UnitTypeName | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'ASC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'UnitTypeName', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'UnitTypeName';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT u.Id, u.UnitTypeName, u.IsActive, u.CreatedAtUtc, u.CreatedBy, u.UpdatedAtUtc, u.UpdatedBy, u.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.UnitTypes u
    WHERE (@Search IS NULL OR u.UnitTypeName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'UnitTypeName' THEN u.UnitTypeName END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'UnitTypeName' THEN u.UnitTypeName END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(u.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(u.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN u.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN u.CreatedAtUtc END DESC,
        u.UnitTypeName ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UnitTypeName, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.UnitTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UnitTypeName, IsActive
    FROM masterdata.UnitTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY UnitTypeName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Create
    @UnitTypeName NVARCHAR(50),
    @IsActive     BIT = 1,
    @UserId       INT = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @UnitTypeName = LTRIM(RTRIM(@UnitTypeName));
    SET @IsActive = ISNULL(@IsActive, 1);

    IF @UnitTypeName IS NULL OR @UnitTypeName = N''
        THROW 57000, 'Unit Type name is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE UnitTypeName = @UnitTypeName)
        THROW 57001, 'A unit type with this name already exists.', 1;

    INSERT INTO masterdata.UnitTypes (UnitTypeName, IsActive, CreatedBy) VALUES (@UnitTypeName, @IsActive, @UserId);
    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Update
    @Id           INT,
    @UnitTypeName NVARCHAR(50),
    @IsActive     BIT       = 1,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @UnitTypeName = LTRIM(RTRIM(@UnitTypeName));
    SET @IsActive = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id)
        THROW 57006, 'Unit type not found.', 1;
    IF @UnitTypeName IS NULL OR @UnitTypeName = N''
        THROW 57000, 'Unit Type name is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE UnitTypeName = @UnitTypeName AND Id <> @Id)
        THROW 57001, 'A unit type with this name already exists.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 57004, 'This unit type was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.UnitTypes
    SET UnitTypeName = @UnitTypeName, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id)
        THROW 57006, 'Unit type not found.', 1;
    UPDATE masterdata.UnitTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitType_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id)
        THROW 57006, 'Unit type not found.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.UnitTypes');

    DECLARE @Referenced BIT = 0;
    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    IF @Referenced = 1
        THROW 57003, 'This unit type cannot be deleted because it is used by item units. You may deactivate it instead.', 1;

    DELETE FROM masterdata.UnitTypes WHERE Id = @Id;
END
GO

/* ================================================================== B. ITEMS (inventory) */

IF OBJECT_ID(N'inventory.Items', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.Items
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        ItemCode           NVARCHAR(30)      NOT NULL,
        ItemName           NVARCHAR(200)     NOT NULL,
        BrandId            INT               NOT NULL,
        Model              NVARCHAR(100)     NULL,
        ItemFamilyId       INT               NOT NULL,
        CountryOfOrigin    NVARCHAR(2)       NOT NULL,   -- ISO 3166-1 alpha-2 (e.g. IN)
        DefaultWarehouseId INT               NOT NULL,
        Description        NVARCHAR(1000)    NULL,
        WarrantyMonths     INT               NULL,
        MinQuantity        INT               NOT NULL CONSTRAINT DF_Items_MinQuantity DEFAULT (0),
        MaxQuantity        INT               NULL,
        IsBivac            BIT               NOT NULL CONSTRAINT DF_Items_IsBivac DEFAULT (0),
        IsActive           BIT               NOT NULL CONSTRAINT DF_Items_IsActive DEFAULT (1),
        CreatedAtUtc       DATETIME2(3)      NOT NULL CONSTRAINT DF_Items_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy          INT               NULL,
        UpdatedAtUtc       DATETIME2(3)      NULL,
        UpdatedBy          INT               NULL,
        RowVersion         ROWVERSION        NOT NULL,
        CONSTRAINT PK_Items PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Items_ItemCode UNIQUE (ItemCode),
        CONSTRAINT CK_Items_ItemCode_NotBlank CHECK (LEN(LTRIM(RTRIM(ItemCode))) > 0),
        CONSTRAINT CK_Items_ItemName_NotBlank CHECK (LEN(LTRIM(RTRIM(ItemName))) > 0),
        CONSTRAINT CK_Items_Warranty CHECK (WarrantyMonths IS NULL OR WarrantyMonths >= 0),
        CONSTRAINT CK_Items_MinQuantity CHECK (MinQuantity >= 0),
        CONSTRAINT CK_Items_MaxQuantity CHECK (MaxQuantity IS NULL OR MaxQuantity >= 0),
        CONSTRAINT CK_Items_MinMax CHECK (MaxQuantity IS NULL OR MinQuantity <= MaxQuantity),
        CONSTRAINT FK_Items_Brand     FOREIGN KEY (BrandId)            REFERENCES masterdata.Brands (Id),
        CONSTRAINT FK_Items_Family    FOREIGN KEY (ItemFamilyId)       REFERENCES masterdata.ItemFamilies (Id),
        CONSTRAINT FK_Items_Warehouse FOREIGN KEY (DefaultWarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_Items_CreatedBy FOREIGN KEY (CreatedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_Items_UpdatedBy FOREIGN KEY (UpdatedBy)          REFERENCES security.Users (Id)
    );

    CREATE NONCLUSTERED INDEX IX_Items_ItemName  ON inventory.Items (ItemName);
    CREATE NONCLUSTERED INDEX IX_Items_Family    ON inventory.Items (ItemFamilyId);
    CREATE NONCLUSTERED INDEX IX_Items_Brand     ON inventory.Items (BrandId);
    CREATE NONCLUSTERED INDEX IX_Items_Warehouse ON inventory.Items (DefaultWarehouseId);

    PRINT 'Created inventory.Items';
END
GO

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ItemUnits
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        ItemId         INT               NOT NULL,
        UnitTypeId     INT               NOT NULL,
        PackingFormula INT               NOT NULL,    -- how many BASE units this unit holds (base = 1)
        SkuCode        NVARCHAR(50)      NOT NULL,
        Barcode        NVARCHAR(50)      NULL,        -- unique across the whole system
        IsSalesUnit    BIT               NOT NULL CONSTRAINT DF_ItemUnits_IsSalesUnit DEFAULT (0),
        IsPurchaseUnit BIT               NOT NULL CONSTRAINT DF_ItemUnits_IsPurchaseUnit DEFAULT (0),
        IsBaseUnit     BIT               NOT NULL CONSTRAINT DF_ItemUnits_IsBaseUnit DEFAULT (0),
        CreatedAtUtc   DATETIME2(3)      NOT NULL CONSTRAINT DF_ItemUnits_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT               NULL,
        UpdatedAtUtc   DATETIME2(3)      NULL,
        UpdatedBy      INT               NULL,
        RowVersion     ROWVERSION        NOT NULL,
        CONSTRAINT PK_ItemUnits PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ItemUnits_Item_UnitType UNIQUE (ItemId, UnitTypeId),
        CONSTRAINT UQ_ItemUnits_Item_Sku UNIQUE (ItemId, SkuCode),
        CONSTRAINT CK_ItemUnits_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_ItemUnits_BaseFormula CHECK (IsBaseUnit = 0 OR PackingFormula = 1),
        CONSTRAINT CK_ItemUnits_Sku_NotBlank CHECK (LEN(LTRIM(RTRIM(SkuCode))) > 0),
        CONSTRAINT FK_ItemUnits_Item     FOREIGN KEY (ItemId)     REFERENCES inventory.Items (Id),
        CONSTRAINT FK_ItemUnits_UnitType FOREIGN KEY (UnitTypeId) REFERENCES masterdata.UnitTypes (Id),
        CONSTRAINT FK_ItemUnits_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_ItemUnits_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    -- Exactly one base unit per item (at most one here; "at least one" is enforced by the procedures).
    CREATE UNIQUE NONCLUSTERED INDEX UX_ItemUnits_BaseUnit ON inventory.ItemUnits (ItemId) WHERE IsBaseUnit = 1;
    -- Barcode unique across the system (scanners resolve a barcode alone).
    CREATE UNIQUE NONCLUSTERED INDEX UX_ItemUnits_Barcode ON inventory.ItemUnits (Barcode) WHERE Barcode IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_ItemUnits_Item ON inventory.ItemUnits (ItemId);

    PRINT 'Created inventory.ItemUnits';
END
GO

IF OBJECT_ID(N'inventory.ItemFiles', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ItemFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        ItemId       INT               NOT NULL,
        FileName     NVARCHAR(255)     NOT NULL,
        ContentType  NVARCHAR(100)     NOT NULL,
        SizeBytes    INT               NOT NULL,
        IsItemImage  BIT               NOT NULL CONSTRAINT DF_ItemFiles_IsItemImage DEFAULT (0),
        Content      VARBINARY(MAX)    NOT NULL,
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_ItemFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        CONSTRAINT PK_ItemFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ItemFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_ItemFiles_Item FOREIGN KEY (ItemId) REFERENCES inventory.Items (Id),
        CONSTRAINT FK_ItemFiles_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id)
    );

    -- One item image per item; other rows are ordinary attachments.
    CREATE UNIQUE NONCLUSTERED INDEX UX_ItemFiles_ItemImage ON inventory.ItemFiles (ItemId) WHERE IsItemImage = 1;
    CREATE NONCLUSTERED INDEX IX_ItemFiles_Item ON inventory.ItemFiles (ItemId);

    PRINT 'Created inventory.ItemFiles';
END
GO

/* ------------------------------------------------------------------ Item procedures */

CREATE OR ALTER PROCEDURE inventory.usp_Item_Search
    @Search             NVARCHAR(200) = NULL,   -- Item Code, Item Name, or any unit SKU / Barcode
    @ItemFamilyId       INT           = NULL,   -- filters the family AND its whole subtree
    @BrandId            INT           = NULL,
    @DefaultWarehouseId INT           = NULL,
    @IsActive           BIT           = NULL,
    @IsBivac            BIT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'ItemCode', -- ItemCode | ItemName | BrandName | FamilyName | WarehouseName | IsActive | CreatedAtUtc
    @SortDirection      NVARCHAR(4)   = N'ASC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BrandName', N'FamilyName', N'WarehouseName', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           bu.SkuCode AS BaseUnitSku, ut.UnitTypeName AS BaseUnitName,
           CAST(0 AS INT) AS OnHand,                                   -- placeholder until the stock module
           i.CreatedAtUtc, i.CreatedBy, i.UpdatedAtUtc, i.UpdatedBy, i.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b        ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN inventory.ItemUnits bu     ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes ut    ON ut.Id = bu.UnitTypeId
    WHERE (@Search IS NULL
           OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u
                      WHERE u.ItemId = i.Id
                        AND (u.SkuCode LIKE N'%' + @Search + N'%' OR u.Barcode LIKE N'%' + @Search + N'%')))
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@DefaultWarehouseId IS NULL OR i.DefaultWarehouseId = @DefaultWarehouseId)
      AND (@IsActive IS NULL OR i.IsActive = @IsActive)
      AND (@IsBivac IS NULL OR i.IsBivac = @IsBivac)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BrandName' THEN b.BrandName WHEN N'FamilyName' THEN f.FamilyName
                             WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BrandName' THEN b.BrandName WHEN N'FamilyName' THEN f.FamilyName
                             WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END DESC,
        i.ItemCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Three result sets: the item (joined names + placeholders), its units, its file metadata (no content).
CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           CAST(0 AS INT) AS OnHand,
           CAST(NULL AS DECIMAL(18,2)) AS LastCost,
           CAST(NULL AS DECIMAL(18,2)) AS AverageCost,
           CAST(NULL AS DECIMAL(18,2)) AS LastPurchaseCost,               -- placeholders until stock/purchasing
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

-- Items for a future Item picker: the item plus the SKU of its base unit.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.Id, i.ItemCode, i.ItemName, bu.SkuCode AS BaseUnitSku, i.IsActive
    FROM inventory.Items i
    LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
    ORDER BY i.ItemCode;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Create
    @ItemCode           NVARCHAR(30),
    @ItemName           NVARCHAR(200),
    @BrandId            INT,
    @Model              NVARCHAR(100)  = NULL,
    @ItemFamilyId       INT,
    @CountryOfOrigin    NVARCHAR(2),
    @DefaultWarehouseId INT,
    @Description        NVARCHAR(1000) = NULL,
    @WarrantyMonths     INT            = NULL,
    @MinQuantity        INT            = 0,
    @MaxQuantity        INT            = NULL,
    @IsBivac            BIT            = 0,
    @IsActive           BIT            = 1,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @ItemCode        = LTRIM(RTRIM(@ItemCode));
    SET @ItemName        = LTRIM(RTRIM(@ItemName));
    SET @Model           = NULLIF(LTRIM(RTRIM(@Model)), N'');
    SET @CountryOfOrigin = UPPER(LTRIM(RTRIM(@CountryOfOrigin)));
    SET @Description     = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @MinQuantity     = ISNULL(@MinQuantity, 0);
    SET @IsBivac         = ISNULL(@IsBivac, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF @ItemCode IS NULL OR @ItemCode = N'' THROW 56000, 'Item Code is required.', 1;
    IF @ItemName IS NULL OR @ItemName = N'' THROW 56000, 'Item Name is required.', 1;
    IF @CountryOfOrigin IS NULL OR LEN(@CountryOfOrigin) <> 2 OR @CountryOfOrigin LIKE N'%[^A-Z]%'
        THROW 56000, 'Country of Origin is required (2-letter ISO code).', 1;
    IF @WarrantyMonths IS NOT NULL AND @WarrantyMonths < 0 THROW 56000, 'Warranty cannot be negative.', 1;
    IF @MinQuantity < 0 THROW 56000, 'Minimum Quantity cannot be negative.', 1;
    IF @MaxQuantity IS NOT NULL AND @MaxQuantity < @MinQuantity
        THROW 56000, 'Minimum Quantity cannot exceed Maximum Quantity.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @BrandId AND IsActive = 1)
        THROW 56008, 'Brand not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @ItemFamilyId AND IsActive = 1)
        THROW 56008, 'Item Family not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 56008, 'Default Warehouse not found or inactive.', 1;

    IF EXISTS (SELECT 1 FROM inventory.Items WHERE ItemCode = @ItemCode)
        THROW 56001, 'An item with this Item Code already exists.', 1;

    INSERT INTO inventory.Items (ItemCode, ItemName, BrandId, Model, ItemFamilyId, CountryOfOrigin,
                                 DefaultWarehouseId, Description, WarrantyMonths, MinQuantity, MaxQuantity,
                                 IsBivac, IsActive, CreatedBy)
    VALUES (@ItemCode, @ItemName, @BrandId, @Model, @ItemFamilyId, @CountryOfOrigin,
            @DefaultWarehouseId, @Description, @WarrantyMonths, @MinQuantity, @MaxQuantity,
            @IsBivac, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Update
    @Id                 INT,
    @ItemCode           NVARCHAR(30),
    @ItemName           NVARCHAR(200),
    @BrandId            INT,
    @Model              NVARCHAR(100)  = NULL,
    @ItemFamilyId       INT,
    @CountryOfOrigin    NVARCHAR(2),
    @DefaultWarehouseId INT,
    @Description        NVARCHAR(1000) = NULL,
    @WarrantyMonths     INT            = NULL,
    @MinQuantity        INT            = 0,
    @MaxQuantity        INT            = NULL,
    @IsBivac            BIT            = 0,
    @IsActive           BIT            = 1,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ItemCode        = LTRIM(RTRIM(@ItemCode));
    SET @ItemName        = LTRIM(RTRIM(@ItemName));
    SET @Model           = NULLIF(LTRIM(RTRIM(@Model)), N'');
    SET @CountryOfOrigin = UPPER(LTRIM(RTRIM(@CountryOfOrigin)));
    SET @Description     = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @MinQuantity     = ISNULL(@MinQuantity, 0);
    SET @IsBivac         = ISNULL(@IsBivac, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;
    IF @ItemCode IS NULL OR @ItemCode = N'' THROW 56000, 'Item Code is required.', 1;
    IF @ItemName IS NULL OR @ItemName = N'' THROW 56000, 'Item Name is required.', 1;
    IF @CountryOfOrigin IS NULL OR LEN(@CountryOfOrigin) <> 2 OR @CountryOfOrigin LIKE N'%[^A-Z]%'
        THROW 56000, 'Country of Origin is required (2-letter ISO code).', 1;
    IF @WarrantyMonths IS NOT NULL AND @WarrantyMonths < 0 THROW 56000, 'Warranty cannot be negative.', 1;
    IF @MinQuantity < 0 THROW 56000, 'Minimum Quantity cannot be negative.', 1;
    IF @MaxQuantity IS NOT NULL AND @MaxQuantity < @MinQuantity
        THROW 56000, 'Minimum Quantity cannot exceed Maximum Quantity.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @BrandId AND IsActive = 1)
        THROW 56008, 'Brand not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @ItemFamilyId AND IsActive = 1)
        THROW 56008, 'Item Family not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 56008, 'Default Warehouse not found or inactive.', 1;

    IF EXISTS (SELECT 1 FROM inventory.Items WHERE ItemCode = @ItemCode AND Id <> @Id)
        THROW 56001, 'An item with this Item Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 56004, 'This item was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.Items
    SET ItemCode = @ItemCode, ItemName = @ItemName, BrandId = @BrandId, Model = @Model,
        ItemFamilyId = @ItemFamilyId, CountryOfOrigin = @CountryOfOrigin,
        DefaultWarehouseId = @DefaultWarehouseId, Description = @Description,
        WarrantyMonths = @WarrantyMonths, MinQuantity = @MinQuantity, MaxQuantity = @MaxQuantity,
        IsBivac = @IsBivac, IsActive = @IsActive,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;
    UPDATE inventory.Items SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

-- Deletes the item with its units and files, but only when no OTHER table references the item
-- or any of its units (future stock/purchase/invoice lines). sys.foreign_keys covers new tables automatically.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;

    DECLARE @Referenced BIT = 0, @sql NVARCHAR(MAX) = N'';

    -- References to the item itself (excluding its own child tables).
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.Items')
      AND fk.parent_object_id NOT IN (OBJECT_ID(N'inventory.ItemUnits'), OBJECT_ID(N'inventory.ItemFiles'));

    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    -- References to any of the item's units (e.g. future transaction lines storing ItemUnitId).
    IF @Referenced = 0
    BEGIN
        SET @sql = N'';
        SELECT @sql = @sql
            + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' x'
            + N' INNER JOIN inventory.ItemUnits iu ON iu.Id = x.' + QUOTENAME(c.name)
            + N' WHERE iu.ItemId = @Id) SET @Referenced = 1;' + NCHAR(10)
        FROM sys.foreign_keys fk
        INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
        INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.ItemUnits');

        IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    END

    IF @Referenced = 1
        THROW 56003, 'This item cannot be deleted because it is referenced by inventory or transactions. You may deactivate it instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM inventory.ItemFiles WHERE ItemId = @Id;
        DELETE FROM inventory.ItemUnits WHERE ItemId = @Id;
        DELETE FROM inventory.Items WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ Item unit procedures */

CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_Create
    @ItemId         INT,
    @UnitTypeId     INT,
    @PackingFormula INT,
    @SkuCode        NVARCHAR(50),
    @Barcode        NVARCHAR(50) = NULL,
    @IsSalesUnit    BIT          = 0,
    @IsPurchaseUnit BIT          = 0,
    @IsBaseUnit     BIT          = 0,
    @UserId         INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SkuCode = LTRIM(RTRIM(@SkuCode));
    SET @Barcode = NULLIF(LTRIM(RTRIM(@Barcode)), N'');
    SET @IsSalesUnit = ISNULL(@IsSalesUnit, 0);
    SET @IsPurchaseUnit = ISNULL(@IsPurchaseUnit, 0);
    SET @IsBaseUnit = ISNULL(@IsBaseUnit, 0);

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId)
        THROW 56006, 'Item not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @UnitTypeId AND IsActive = 1)
        THROW 56008, 'Unit Type not found or inactive.', 1;
    IF @SkuCode IS NULL OR @SkuCode = N'' THROW 56000, 'SKU Code is required.', 1;
    IF @PackingFormula IS NULL OR @PackingFormula < 1
        THROW 56000, 'Packing Formula must be a whole number of at least 1.', 1;

    DECLARE @HasBase BIT = CASE WHEN EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1) THEN 1 ELSE 0 END;

    IF @HasBase = 0 AND @IsBaseUnit = 0
        THROW 56005, 'The first unit of an item must be the Base Unit.', 1;
    IF @HasBase = 1 AND @IsBaseUnit = 1
        THROW 56005, 'This item already has a Base Unit. Edit the existing units to change which one is the base.', 1;
    IF @IsBaseUnit = 1 AND @PackingFormula <> 1
        THROW 56005, 'The Base Unit must have a Packing Formula of 1.', 1;

    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND UnitTypeId = @UnitTypeId)
        THROW 56000, 'This item already has a unit of this Unit Type.', 1;
    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND SkuCode = @SkuCode)
        THROW 56007, 'This SKU Code is already used by another unit of this item.', 1;
    IF @Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Barcode = @Barcode)
        THROW 56002, 'This Barcode is already used by another unit in the system.', 1;

    INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode,
                                     IsSalesUnit, IsPurchaseUnit, IsBaseUnit, CreatedBy)
    VALUES (@ItemId, @UnitTypeId, @PackingFormula, @SkuCode, @Barcode,
            @IsSalesUnit, @IsPurchaseUnit, @IsBaseUnit, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_Update
    @Id             INT,
    @UnitTypeId     INT,
    @PackingFormula INT,
    @SkuCode        NVARCHAR(50),
    @Barcode        NVARCHAR(50) = NULL,
    @IsSalesUnit    BIT          = 0,
    @IsPurchaseUnit BIT          = 0,
    @IsBaseUnit     BIT          = 0,
    @RowVersion     BINARY(8)    = NULL,
    @UserId         INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SkuCode = LTRIM(RTRIM(@SkuCode));
    SET @Barcode = NULLIF(LTRIM(RTRIM(@Barcode)), N'');
    SET @IsSalesUnit = ISNULL(@IsSalesUnit, 0);
    SET @IsPurchaseUnit = ISNULL(@IsPurchaseUnit, 0);
    SET @IsBaseUnit = ISNULL(@IsBaseUnit, 0);

    DECLARE @ItemId INT, @WasBase BIT;
    SELECT @ItemId = ItemId, @WasBase = IsBaseUnit FROM inventory.ItemUnits WHERE Id = @Id;

    IF @ItemId IS NULL
        THROW 56006, 'Item unit not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @UnitTypeId AND IsActive = 1)
        THROW 56008, 'Unit Type not found or inactive.', 1;
    IF @SkuCode IS NULL OR @SkuCode = N'' THROW 56000, 'SKU Code is required.', 1;
    IF @PackingFormula IS NULL OR @PackingFormula < 1
        THROW 56000, 'Packing Formula must be a whole number of at least 1.', 1;
    IF @WasBase = 1 AND @IsBaseUnit = 0
        THROW 56005, 'Every item needs a Base Unit. Mark another unit as the base instead (that switches automatically).', 1;
    IF @IsBaseUnit = 1 AND @PackingFormula <> 1
        THROW 56005, 'The Base Unit must have a Packing Formula of 1.', 1;

    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND UnitTypeId = @UnitTypeId AND Id <> @Id)
        THROW 56000, 'This item already has a unit of this Unit Type.', 1;
    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND SkuCode = @SkuCode AND Id <> @Id)
        THROW 56007, 'This SKU Code is already used by another unit of this item.', 1;
    IF @Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Barcode = @Barcode AND Id <> @Id)
        THROW 56002, 'This Barcode is already used by another unit in the system.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 56004, 'This unit was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Becoming the base demotes the current base (single-base invariant).
        IF @IsBaseUnit = 1 AND @WasBase = 0
        BEGIN
            UPDATE inventory.ItemUnits
            SET IsBaseUnit = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE ItemId = @ItemId AND IsBaseUnit = 1;
        END

        UPDATE inventory.ItemUnits
        SET UnitTypeId = @UnitTypeId, PackingFormula = @PackingFormula, SkuCode = @SkuCode, Barcode = @Barcode,
            IsSalesUnit = @IsSalesUnit, IsPurchaseUnit = @IsPurchaseUnit, IsBaseUnit = @IsBaseUnit,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsBase BIT = (SELECT IsBaseUnit FROM inventory.ItemUnits WHERE Id = @Id);
    IF @IsBase IS NULL
        THROW 56006, 'Item unit not found.', 1;
    IF @IsBase = 1
        THROW 56005, 'The Base Unit cannot be deleted. Mark another unit as the base first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.ItemUnits');

    DECLARE @Referenced BIT = 0;
    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    IF @Referenced = 1
        THROW 56003, 'This unit cannot be deleted because it is referenced by transactions.', 1;

    DELETE FROM inventory.ItemUnits WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ Item file procedures */

CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_Add
    @ItemId      INT,
    @FileName    NVARCHAR(255),
    @ContentType NVARCHAR(100),
    @SizeBytes   INT,
    @IsItemImage BIT,
    @Content     VARBINARY(MAX),
    @UserId      INT = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId)
        THROW 56006, 'Item not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 56000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 56000, 'The file is empty.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsItemImage = 1
            DELETE FROM inventory.ItemFiles WHERE ItemId = @ItemId AND IsItemImage = 1;  -- replace the image

        INSERT INTO inventory.ItemFiles (ItemId, FileName, ContentType, SizeBytes, IsItemImage, Content, CreatedBy)
        VALUES (@ItemId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, ISNULL(@IsItemImage, 0), @Content, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ItemId, FileName, ContentType, SizeBytes, IsItemImage, Content, CreatedAtUtc
    FROM inventory.ItemFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemFile_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.ItemFiles WHERE Id = @Id)
        THROW 56006, 'File not found.', 1;
    DELETE FROM inventory.ItemFiles WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.unittypes.view',   N'View unit types',   N'Master Data', N'See the Unit Types list.',                              340),
        (N'masterdata.unittypes.create', N'Create unit types', N'Master Data', N'Add new unit types.',                                   350),
        (N'masterdata.unittypes.edit',   N'Edit unit types',   N'Master Data', N'Change unit types and activate / deactivate them.',     360),
        (N'masterdata.unittypes.delete', N'Delete unit types', N'Master Data', N'Delete unit types not used by items.',                  370),
        (N'inventory.items.view',        N'View items',        N'Inventory',   N'See the Item Definition list and item details.',        400),
        (N'inventory.items.create',      N'Create items',      N'Inventory',   N'Add new items with units and attachments.',             410),
        (N'inventory.items.edit',        N'Edit items',        N'Inventory',   N'Change items, units, attachments and status.',          420),
        (N'inventory.items.delete',      N'Delete items',      N'Inventory',   N'Delete items not referenced by transactions.',          430)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'masterdata.unittypes.%' OR p.Code LIKE N'inventory.items.%')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'masterdata.unittypes.view', N'inventory.items.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ Seeds */

IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes)
BEGIN
    INSERT INTO masterdata.UnitTypes (UnitTypeName, IsActive)
    VALUES (N'PC', 1), (N'Box', 1), (N'Pallet', 1), (N'Container', 1);
    PRINT 'Seeded unit types: PC, Box, Pallet, Container (dummy data - edit freely).';
END
GO

-- One demo item, only when every prerequisite seed is present and Items is empty.
IF NOT EXISTS (SELECT 1 FROM inventory.Items)
BEGIN
    DECLARE @BrandId INT      = (SELECT TOP (1) Id FROM masterdata.Brands       WHERE BrandName  = N'TVS' AND IsActive = 1);
    DECLARE @FamilyId INT     = (SELECT TOP (1) Id FROM masterdata.ItemFamilies WHERE FamilyName = N'Motorcycles' AND IsActive = 1);
    DECLARE @WarehouseId INT  = (SELECT TOP (1) Id FROM masterdata.Warehouses   WHERE IsMainWarehouse = 1 AND IsActive = 1);
    DECLARE @PcId INT         = (SELECT TOP (1) Id FROM masterdata.UnitTypes    WHERE UnitTypeName = N'PC');

    IF @BrandId IS NOT NULL AND @FamilyId IS NOT NULL AND @WarehouseId IS NOT NULL AND @PcId IS NOT NULL
    BEGIN
        DECLARE @ItemId INT;

        INSERT INTO inventory.Items (ItemCode, ItemName, BrandId, Model, ItemFamilyId, CountryOfOrigin,
                                     DefaultWarehouseId, Description, WarrantyMonths, MinQuantity, MaxQuantity, IsBivac, IsActive)
        VALUES (N'TVS-AP160', N'TVS Apache RTR 160 4V', @BrandId, N'Apache RTR 160 4V', @FamilyId, N'IN',
                @WarehouseId, N'High performance 160cc motorcycle.', 24, 1, 99999, 0, 1);
        SET @ItemId = SCOPE_IDENTITY();

        INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode, IsSalesUnit, IsPurchaseUnit, IsBaseUnit)
        VALUES (@ItemId, @PcId, 1, N'AP160-PC', NULL, 1, 1, 1);

        PRINT 'Seeded demo item TVS-AP160 with its PC base unit.';
    END
END
GO


-- ===== 12: Master Data - Price Lists + Unit Price List =====

/* =====================================================================================
   Inventory_Shipment - 12: Price Lists + Unit Price List   (user story US-MD-006)
   DATABASE ONLY (pages come later).

   Schema:  masterdata
   Tables:  masterdata.PriceLists         - header: code, name, currency, active
            masterdata.UnitPrices         - ONE current selling price per
                                            Branch (NULL = All Branches) + Item Unit + Price List
            masterdata.UnitPriceHistory   - system-generated, read-only log of every change
   Procs:   masterdata.usp_PriceList_Search / _Get / _Lookup / _Create / _Update / _SetActive / _Delete
            masterdata.usp_UnitPrice_Search / _Get / _Create / _Update / _SetActive / _Delete /
            _History / _Resolve
            inventory.usp_Item_Lookup, inventory.usp_ItemUnit_ListByItem   (grid dropdown helpers)
   Func:    masterdata.fn_GetUnitPrice (branch-specific -> all-branches -> NULL)
   Seeds:   permissions masterdata.pricelists.* (440-470) and masterdata.unitprices.* (480-510);
            price list PL-001 "Retail USD" (currency USD); a demo price for TVS-AP160 / PC when present.

   Design:
     - Currency belongs to the PRICE LIST; every price in it is in that currency. The currency of a
       price list can no longer be changed once it contains prices (58009).
     - A price row is the CURRENT price for its key; changing the price updates the row and writes a
       history record (old -> new). History survives deletion (no FK, names snapshotted).
     - Price lookup priority (fn_GetUnitPrice / usp_UnitPrice_Resolve):
         1. active price for the exact branch  2. active "All Branches" price  3. NULL (no price)
     - Keys (Branch, Item, Unit, Price List) are immutable after creation: edit changes Price/Status;
       a different key = new row. Unit must belong to the item.
     - Price DECIMAL(18,4) >= 0. Quantities are pieces; the price is per the chosen UNIT (PC, Box...).

   Error numbers (read by the API):
     Price lists: 58000 validation, 58001 duplicate code / name, 58003 referenced (delete),
                  58004 concurrency, 58006 not found, 58008 currency missing/inactive,
                  58009 currency locked (price list already has prices)
     Unit prices: 59000 validation, 59001 duplicate key (branch + item + unit + price list),
                  59004 concurrency, 59006 not found, 59007 unit does not belong to the item,
                  59008 related master data missing/inactive (branch, item, price list)

   Requires 01, 03, 06 (Branches), 08 (Currencies), 11 (Items). Idempotent. SQL Server 2016 SP1+.
   ===================================================================================== */


IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'masterdata.Branches', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL OR OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 01, 03, 06, 08 and 11 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'masterdata.PriceLists', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.PriceLists
    (
        Id            INT IDENTITY(1,1) NOT NULL,
        PriceListCode NVARCHAR(20)      NOT NULL,
        PriceListName NVARCHAR(100)     NOT NULL,
        CurrencyId    INT               NOT NULL,
        Description   NVARCHAR(500)     NULL,
        IsActive      BIT               NOT NULL CONSTRAINT DF_PriceLists_IsActive DEFAULT (1),
        CreatedAtUtc  DATETIME2(3)      NOT NULL CONSTRAINT DF_PriceLists_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy     INT               NULL,
        UpdatedAtUtc  DATETIME2(3)      NULL,
        UpdatedBy     INT               NULL,
        RowVersion    ROWVERSION        NOT NULL,
        CONSTRAINT PK_PriceLists PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PriceLists_Code UNIQUE (PriceListCode),
        CONSTRAINT UQ_PriceLists_Name UNIQUE (PriceListName),
        CONSTRAINT CK_PriceLists_Code_NotBlank CHECK (LEN(LTRIM(RTRIM(PriceListCode))) > 0),
        CONSTRAINT CK_PriceLists_Name_NotBlank CHECK (LEN(LTRIM(RTRIM(PriceListName))) > 0),
        CONSTRAINT FK_PriceLists_Currency  FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_PriceLists_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_PriceLists_UpdatedBy FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.PriceLists';
END
GO

IF OBJECT_ID(N'masterdata.UnitPrices', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.UnitPrices
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        BranchId     INT               NULL,        -- NULL = All Branches
        ItemId       INT               NOT NULL,
        ItemUnitId   INT               NOT NULL,    -- must belong to ItemId (checked by the procs)
        PriceListId  INT               NOT NULL,
        Price        DECIMAL(18,4)     NOT NULL,    -- in the price list currency, per the unit
        IsActive     BIT               NOT NULL CONSTRAINT DF_UnitPrices_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_UnitPrices_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_UnitPrices PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_UnitPrices_Price CHECK (Price >= 0),
        CONSTRAINT FK_UnitPrices_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_UnitPrices_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_UnitPrices_ItemUnit  FOREIGN KEY (ItemUnitId)  REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_UnitPrices_PriceList FOREIGN KEY (PriceListId) REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_UnitPrices_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES security.Users (Id),
        CONSTRAINT FK_UnitPrices_UpdatedBy FOREIGN KEY (UpdatedBy)   REFERENCES security.Users (Id)
    );

    -- One current price per Branch + Unit + Price List. NULL branches compare equal in a unique
    -- index, so this also enforces a single "All Branches" price per Unit + Price List.
    CREATE UNIQUE NONCLUSTERED INDEX UX_UnitPrices_Key
        ON masterdata.UnitPrices (ItemUnitId, PriceListId, BranchId);

    CREATE NONCLUSTERED INDEX IX_UnitPrices_Item      ON masterdata.UnitPrices (ItemId);
    CREATE NONCLUSTERED INDEX IX_UnitPrices_PriceList ON masterdata.UnitPrices (PriceListId);
    CREATE NONCLUSTERED INDEX IX_UnitPrices_Branch    ON masterdata.UnitPrices (BranchId);

    PRINT 'Created masterdata.UnitPrices';
END
GO

IF OBJECT_ID(N'masterdata.UnitPriceHistory', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.UnitPriceHistory
    (
        Id            BIGINT IDENTITY(1,1) NOT NULL,
        UnitPriceId   INT            NULL,       -- no FK on purpose: history outlives the price row
        BranchId      INT            NULL,
        BranchName    NVARCHAR(150)  NOT NULL,   -- snapshot; 'All Branches' when BranchId is NULL
        ItemId        INT            NOT NULL,
        ItemCode      NVARCHAR(30)   NOT NULL,   -- snapshot
        ItemName      NVARCHAR(200)  NOT NULL,   -- snapshot
        ItemUnitId    INT            NOT NULL,
        UnitTypeName  NVARCHAR(50)   NOT NULL,   -- snapshot
        PriceListId   INT            NOT NULL,
        PriceListName NVARCHAR(100)  NOT NULL,   -- snapshot
        CurrencyCode  NVARCHAR(3)    NOT NULL,   -- snapshot
        OldPrice      DECIMAL(18,4)  NULL,
        NewPrice      DECIMAL(18,4)  NULL,
        ChangeType    TINYINT        NOT NULL,   -- 1 Created, 2 PriceChanged, 3 Activated, 4 Deactivated, 5 Deleted
        ChangedBy     INT            NULL,
        ChangedByName NVARCHAR(100)  NOT NULL,   -- snapshot
        ChangedAtUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_UnitPriceHistory_ChangedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_UnitPriceHistory PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_UnitPriceHistory_ChangeType CHECK (ChangeType BETWEEN 1 AND 5),
        CONSTRAINT FK_UnitPriceHistory_ChangedBy FOREIGN KEY (ChangedBy) REFERENCES security.Users (Id)
    );

    -- History is read per key (Branch + Unit + Price List), newest first.
    CREATE NONCLUSTERED INDEX IX_UnitPriceHistory_Key
        ON masterdata.UnitPriceHistory (ItemUnitId, PriceListId, BranchId, ChangedAtUtc DESC);

    PRINT 'Created masterdata.UnitPriceHistory';
END
GO

/* ================================================================== 2. Helpers */

-- Writes one history row for a price (snapshots names so the log stays readable after deletions).
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_LogHistory
    @UnitPriceId INT,
    @ChangeType  TINYINT,          -- 1 Created, 2 PriceChanged, 3 Activated, 4 Deactivated, 5 Deleted
    @OldPrice    DECIMAL(18,4) = NULL,
    @NewPrice    DECIMAL(18,4) = NULL,
    @UserId      INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO masterdata.UnitPriceHistory
        (UnitPriceId, BranchId, BranchName, ItemId, ItemCode, ItemName, ItemUnitId, UnitTypeName,
         PriceListId, PriceListName, CurrencyCode, OldPrice, NewPrice, ChangeType, ChangedBy, ChangedByName)
    SELECT up.Id, up.BranchId, ISNULL(b.BranchName, N'All Branches'), up.ItemId, i.ItemCode, i.ItemName,
           up.ItemUnitId, ut.UnitTypeName, up.PriceListId, pl.PriceListName, c.CurrencyCode,
           @OldPrice, @NewPrice, @ChangeType, @UserId, ISNULL(u.FullName, N'System')
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id  = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id  = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id  = up.BranchId
    LEFT  JOIN security.Users u         ON u.Id  = @UserId
    WHERE up.Id = @UnitPriceId;
END
GO

-- Item search for the grid ("Search & Select Item"): code or name, active only by default.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 20;
    IF @Top > 200 SET @Top = 200;

    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId
    FROM inventory.Items i
    LEFT JOIN inventory.ItemUnits bu    ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT JOIN masterdata.UnitTypes ut   ON ut.Id = bu.UnitTypeId
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END
GO

-- Units configured for one item ("Unit" dropdown): base first.
CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_ListByItem
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @ItemId
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;
END
GO

/* ================================================================== 3. Price list procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Search
    @Search        NVARCHAR(100) = NULL,          -- code or name
    @CurrencyId    INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PriceListCode', -- PriceListCode | PriceListName | CurrencyCode | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PriceListCode', N'PriceListName', N'CurrencyCode', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'PriceListCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.CurrencyName, c.DecimalPlaces,
           pl.Description, pl.IsActive,
           PriceCount = (SELECT COUNT(*) FROM masterdata.UnitPrices up WHERE up.PriceListId = pl.Id),
           pl.CreatedAtUtc, pl.CreatedBy, pl.UpdatedAtUtc, pl.UpdatedBy, pl.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE (@Search IS NULL OR pl.PriceListCode LIKE N'%' + @Search + N'%' OR pl.PriceListName LIKE N'%' + @Search + N'%')
      AND (@CurrencyId IS NULL OR pl.CurrencyId = @CurrencyId)
      AND (@IsActive IS NULL OR pl.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'PriceListCode' THEN pl.PriceListCode WHEN N'PriceListName' THEN pl.PriceListName
                             WHEN N'CurrencyCode' THEN c.CurrencyCode END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'PriceListCode' THEN pl.PriceListCode WHEN N'PriceListName' THEN pl.PriceListName
                             WHEN N'CurrencyCode' THEN c.CurrencyCode END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(pl.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(pl.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN pl.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN pl.CreatedAtUtc END DESC,
        pl.PriceListCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.CurrencyName, c.DecimalPlaces,
           pl.Description, pl.IsActive,
           PriceCount = (SELECT COUNT(*) FROM masterdata.UnitPrices up WHERE up.PriceListId = pl.Id),
           pl.CreatedAtUtc, pl.CreatedBy, pl.UpdatedAtUtc, pl.UpdatedBy, pl.RowVersion
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE pl.Id = @Id;
END
GO

-- Dropdown data ("Price List" -> currency auto-displayed).
CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, pl.IsActive
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE (@ActiveOnly = 0 OR pl.IsActive = 1 OR pl.Id = @IncludeId)
    ORDER BY pl.PriceListName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Create
    @PriceListCode NVARCHAR(20),
    @PriceListName NVARCHAR(100),
    @CurrencyId    INT,
    @Description   NVARCHAR(500) = NULL,
    @IsActive      BIT           = 1,
    @UserId        INT           = NULL,
    @NewId         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PriceListCode = LTRIM(RTRIM(@PriceListCode));
    SET @PriceListName = LTRIM(RTRIM(@PriceListName));
    SET @Description   = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive      = ISNULL(@IsActive, 1);

    IF @PriceListCode IS NULL OR @PriceListCode = N'' THROW 58000, 'Price List Code is required.', 1;
    IF @PriceListName IS NULL OR @PriceListName = N'' THROW 58000, 'Price List Name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 58008, 'Currency not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListCode = @PriceListCode)
        THROW 58001, 'A price list with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListName = @PriceListName)
        THROW 58001, 'A price list with this name already exists.', 1;

    INSERT INTO masterdata.PriceLists (PriceListCode, PriceListName, CurrencyId, Description, IsActive, CreatedBy)
    VALUES (@PriceListCode, @PriceListName, @CurrencyId, @Description, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Update
    @Id            INT,
    @PriceListCode NVARCHAR(20),
    @PriceListName NVARCHAR(100),
    @CurrencyId    INT,
    @Description   NVARCHAR(500) = NULL,
    @IsActive      BIT           = 1,
    @RowVersion    BINARY(8)     = NULL,
    @UserId        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @PriceListCode = LTRIM(RTRIM(@PriceListCode));
    SET @PriceListName = LTRIM(RTRIM(@PriceListName));
    SET @Description   = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive      = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;
    IF @PriceListCode IS NULL OR @PriceListCode = N'' THROW 58000, 'Price List Code is required.', 1;
    IF @PriceListName IS NULL OR @PriceListName = N'' THROW 58000, 'Price List Name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 58008, 'Currency not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListCode = @PriceListCode AND Id <> @Id)
        THROW 58001, 'A price list with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListName = @PriceListName AND Id <> @Id)
        THROW 58001, 'A price list with this name already exists.', 1;

    -- The currency is locked once prices exist (all its prices are expressed in it).
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id AND CurrencyId <> @CurrencyId)
       AND EXISTS (SELECT 1 FROM masterdata.UnitPrices WHERE PriceListId = @Id)
        THROW 58009, 'The currency cannot be changed because this price list already contains prices. Create a new price list instead.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 58004, 'This price list was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.PriceLists
    SET PriceListCode = @PriceListCode, PriceListName = @PriceListName, CurrencyId = @CurrencyId,
        Description = @Description, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;
    UPDATE masterdata.PriceLists SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

-- Delete only when the list holds no prices and nothing else references it.
CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.PriceLists');

    DECLARE @Referenced BIT = 0;
    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    IF @Referenced = 1
        THROW 58003, 'This price list cannot be deleted because it contains prices or is referenced by other records. You may deactivate it instead.', 1;

    DELETE FROM masterdata.PriceLists WHERE Id = @Id;
END
GO

/* ================================================================== 4. Unit price procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Search
    @Search          NVARCHAR(200) = NULL,   -- Item Code or Item Name
    @BranchId        INT           = NULL,   -- a branch: its rows only; NULL: no branch filter
    @AllBranchesOnly BIT           = 0,      -- 1: only "All Branches" rows (BranchId IS NULL)
    @PriceListId     INT           = NULL,
    @ItemFamilyId    INT           = NULL,   -- family and its whole subtree
    @BaseUnitTypeId  INT           = NULL,   -- "Basic Unit" filter: the item's base unit type
    @UnitTypeId      INT           = NULL,   -- "Unit" filter: the priced unit's type
    @IsActive        BIT           = NULL,
    @SortColumn      NVARCHAR(30)  = N'ItemCode', -- ItemCode | ItemName | BranchName | UnitTypeName | PriceListName | Price | IsActive | UpdatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BranchName', N'UnitTypeName', N'PriceListName', N'Price', N'IsActive', N'UpdatedAtUtc')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT up.Id, up.BranchId, b.BranchCode, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, but.UnitTypeName AS BaseUnitName,
           up.ItemUnitId, iu.UnitTypeId, ut.UnitTypeName, iu.PackingFormula, iu.SkuCode,
           up.PriceListId, pl.PriceListCode, pl.PriceListName,
           pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces,
           up.Price, up.IsActive,
           up.CreatedAtUtc, up.CreatedBy, up.UpdatedAtUtc, up.UpdatedBy, up.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id   = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id  = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id  = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id  = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id   = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id   = up.BranchId
    LEFT  JOIN inventory.ItemUnits bu   ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes but ON but.Id = bu.UnitTypeId
    WHERE (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR up.BranchId = @BranchId)
      AND (@AllBranchesOnly = 0 OR up.BranchId IS NULL)
      AND (@PriceListId IS NULL OR up.PriceListId = @PriceListId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BaseUnitTypeId IS NULL OR bu.UnitTypeId = @BaseUnitTypeId)
      AND (@UnitTypeId IS NULL OR iu.UnitTypeId = @UnitTypeId)
      AND (@IsActive IS NULL OR up.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BranchName' THEN ISNULL(b.BranchName, N'') WHEN N'UnitTypeName' THEN ut.UnitTypeName
                             WHEN N'PriceListName' THEN pl.PriceListName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BranchName' THEN ISNULL(b.BranchName, N'') WHEN N'UnitTypeName' THEN ut.UnitTypeName
                             WHEN N'PriceListName' THEN pl.PriceListName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Price' THEN up.Price END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Price' THEN up.Price END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(up.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(up.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'UpdatedAtUtc' THEN ISNULL(up.UpdatedAtUtc, up.CreatedAtUtc) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'UpdatedAtUtc' THEN ISNULL(up.UpdatedAtUtc, up.CreatedAtUtc) END DESC,
        i.ItemCode ASC, pl.PriceListName ASC, ut.UnitTypeName ASC, ISNULL(b.BranchName, N'') ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT up.Id, up.BranchId, b.BranchCode, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, but.UnitTypeName AS BaseUnitName,
           up.ItemUnitId, iu.UnitTypeId, ut.UnitTypeName, iu.PackingFormula, iu.SkuCode,
           up.PriceListId, pl.PriceListCode, pl.PriceListName,
           pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces,
           up.Price, up.IsActive,
           up.CreatedAtUtc, up.CreatedBy, up.UpdatedAtUtc, up.UpdatedBy, up.RowVersion
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id   = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id  = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id  = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id  = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id   = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id   = up.BranchId
    LEFT  JOIN inventory.ItemUnits bu   ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes but ON but.Id = bu.UnitTypeId
    WHERE up.Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Create
    @BranchId    INT           = NULL,   -- NULL = All Branches
    @ItemId      INT,
    @ItemUnitId  INT,
    @PriceListId INT,
    @Price       DECIMAL(18,4),
    @IsActive    BIT           = 1,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @IsActive = ISNULL(@IsActive, 1);

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 59008, 'Branch not found or inactive.', 1;
    IF @ItemId IS NULL THROW 59000, 'Item is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId AND IsActive = 1)
        THROW 59008, 'Item not found or inactive.', 1;
    IF @ItemUnitId IS NULL THROW 59000, 'Unit is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Id = @ItemUnitId AND ItemId = @ItemId)
        THROW 59007, 'The selected unit does not belong to the selected item.', 1;
    IF @PriceListId IS NULL THROW 59000, 'Price List is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 59008, 'Price list not found or inactive.', 1;
    IF @Price IS NULL THROW 59000, 'Price is required.', 1;
    IF @Price < 0 THROW 59000, 'Price cannot be negative.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.UnitPrices
               WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId
                 AND ((BranchId IS NULL AND @BranchId IS NULL) OR BranchId = @BranchId))
        THROW 59001, 'A price already exists for this branch, item, unit, and price list. Please edit the existing record instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO masterdata.UnitPrices (BranchId, ItemId, ItemUnitId, PriceListId, Price, IsActive, CreatedBy)
        VALUES (@BranchId, @ItemId, @ItemUnitId, @PriceListId, @Price, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @NewId, @ChangeType = 1, @OldPrice = NULL, @NewPrice = @Price, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Keys (branch / item / unit / price list) are immutable: edit changes Price and/or Status only.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Update
    @Id         INT,
    @Price      DECIMAL(18,4),
    @IsActive   BIT       = NULL,   -- NULL = leave unchanged
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OldPrice DECIMAL(18,4), @OldActive BIT;
    SELECT @OldPrice = Price, @OldActive = IsActive FROM masterdata.UnitPrices WHERE Id = @Id;

    IF @OldPrice IS NULL
        THROW 59006, 'Unit price not found.', 1;
    IF @Price IS NULL THROW 59000, 'Price is required.', 1;
    IF @Price < 0 THROW 59000, 'Price cannot be negative.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.UnitPrices WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 59004, 'This price was modified by another user. Reload the page and try again.', 1;

    SET @IsActive = ISNULL(@IsActive, @OldActive);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.UnitPrices
        SET Price = @Price, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        IF @Price <> @OldPrice
            EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = 2, @OldPrice = @OldPrice, @NewPrice = @Price, @UserId = @UserId;

        IF @IsActive <> @OldActive
        BEGIN
            DECLARE @StatusType TINYINT = CASE WHEN @IsActive = 1 THEN 3 ELSE 4 END;
            EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = @StatusType, @OldPrice = @Price, @NewPrice = @Price, @UserId = @UserId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Price DECIMAL(18,4), @OldActive BIT;
    SELECT @Price = Price, @OldActive = IsActive FROM masterdata.UnitPrices WHERE Id = @Id;
    IF @Price IS NULL
        THROW 59006, 'Unit price not found.', 1;
    IF @OldActive = @IsActive
        RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.UnitPrices SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        DECLARE @StatusType TINYINT = CASE WHEN @IsActive = 1 THEN 3 ELSE 4 END;
        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = @StatusType, @OldPrice = @Price, @NewPrice = @Price, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Physical delete is allowed (transactions snapshot the price they used); the deletion is logged first.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Price DECIMAL(18,4) = (SELECT Price FROM masterdata.UnitPrices WHERE Id = @Id);
    IF @Price IS NULL
        THROW 59006, 'Unit price not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = 5, @OldPrice = @Price, @NewPrice = NULL, @UserId = @UserId;
        DELETE FROM masterdata.UnitPrices WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- History of one key (Branch + Item Unit + Price List), newest first. Pass @UnitPriceId for an existing
-- row, or the key columns directly (works even after the row was deleted).
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_History
    @UnitPriceId INT = NULL,
    @ItemUnitId  INT = NULL,
    @PriceListId INT = NULL,
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @UnitPriceId IS NOT NULL
        SELECT @ItemUnitId = ItemUnitId, @PriceListId = PriceListId, @BranchId = BranchId
        FROM masterdata.UnitPrices WHERE Id = @UnitPriceId;

    IF @ItemUnitId IS NULL OR @PriceListId IS NULL
        THROW 59000, 'Item unit and price list are required to read the price history.', 1;

    SELECT h.Id, h.UnitPriceId, h.BranchId, h.BranchName, h.ItemId, h.ItemCode, h.ItemName,
           h.ItemUnitId, h.UnitTypeName, h.PriceListId, h.PriceListName, h.CurrencyCode,
           h.OldPrice, h.NewPrice, h.ChangeType,
           CASE h.ChangeType WHEN 1 THEN N'Created' WHEN 2 THEN N'Price Changed' WHEN 3 THEN N'Activated'
                             WHEN 4 THEN N'Deactivated' WHEN 5 THEN N'Deleted' END AS ChangeTypeName,
           h.ChangedBy, h.ChangedByName, h.ChangedAtUtc
    FROM masterdata.UnitPriceHistory h
    WHERE h.ItemUnitId = @ItemUnitId AND h.PriceListId = @PriceListId
      AND ((h.BranchId IS NULL AND @BranchId IS NULL) OR h.BranchId = @BranchId)
    ORDER BY h.ChangedAtUtc DESC, h.Id DESC;
END
GO

/* ================================================================== 5. Price resolution (for sales / invoices later) */

-- Selling price for a unit on a price list at a branch:
-- 1. active branch-specific price  2. active "All Branches" price  3. NULL (no price defined).
CREATE OR ALTER FUNCTION masterdata.fn_GetUnitPrice
(
    @ItemUnitId  INT,
    @PriceListId INT,
    @BranchId    INT      -- NULL = look only at the "All Branches" price
)
RETURNS DECIMAL(18,4)
AS
BEGIN
    DECLARE @Price DECIMAL(18,4);

    IF @BranchId IS NOT NULL
        SELECT @Price = Price FROM masterdata.UnitPrices
        WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1;

    IF @Price IS NULL
        SELECT @Price = Price FROM masterdata.UnitPrices
        WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1;

    RETURN @Price;
END
GO

-- Same rule, returning the full row + where it came from (0 or 1 row). The API answers
-- "No price is defined for the selected item, unit, price list, and branch." when empty.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Resolve
    @ItemUnitId  INT,
    @PriceListId INT,
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) up.Id, up.BranchId, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, up.ItemUnitId, ut.UnitTypeName, iu.PackingFormula,
           up.PriceListId, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.DecimalPlaces, up.Price,
           CASE WHEN up.BranchId IS NULL THEN N'AllBranches' ELSE N'Branch' END AS PriceSource
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id  = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id  = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id  = up.BranchId
    WHERE up.ItemUnitId = @ItemUnitId AND up.PriceListId = @PriceListId AND up.IsActive = 1
      AND (up.BranchId = @BranchId OR up.BranchId IS NULL)
    ORDER BY CASE WHEN up.BranchId IS NULL THEN 1 ELSE 0 END;   -- branch-specific wins
END
GO

/* ================================================================== 6. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.pricelists.view',   N'View price lists',   N'Master Data', N'See the Price Lists page.',                                   440),
        (N'masterdata.pricelists.create', N'Create price lists', N'Master Data', N'Add new price lists.',                                        450),
        (N'masterdata.pricelists.edit',   N'Edit price lists',   N'Master Data', N'Change price lists and activate / deactivate them.',          460),
        (N'masterdata.pricelists.delete', N'Delete price lists', N'Master Data', N'Delete empty price lists.',                                   470),
        (N'masterdata.unitprices.view',   N'View unit prices',   N'Master Data', N'See the Unit Price List and price history.',                  480),
        (N'masterdata.unitprices.create', N'Create unit prices', N'Master Data', N'Add prices for item units.',                                  490),
        (N'masterdata.unitprices.edit',   N'Edit unit prices',   N'Master Data', N'Change prices and activate / deactivate them (logged).',      500),
        (N'masterdata.unitprices.delete', N'Delete unit prices', N'Master Data', N'Delete prices (logged in the price history).',                510)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'masterdata.pricelists.%' OR p.Code LIKE N'masterdata.unitprices.%')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'masterdata.pricelists.view', N'masterdata.unitprices.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 7. Seeds */

IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists)
BEGIN
    DECLARE @UsdId INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE CurrencyCode = N'USD' AND IsActive = 1);
    IF @UsdId IS NOT NULL
    BEGIN
        INSERT INTO masterdata.PriceLists (PriceListCode, PriceListName, CurrencyId, Description, IsActive)
        VALUES (N'PL-001', N'Retail USD', @UsdId, N'Default retail selling prices in US Dollars', 1);
        PRINT 'Seeded price list PL-001 Retail USD';
    END
END
GO

-- Demo price (All Branches) for the demo item's base unit, when everything it needs exists.
IF NOT EXISTS (SELECT 1 FROM masterdata.UnitPrices)
BEGIN
    DECLARE @ItemId INT = (SELECT TOP (1) Id FROM inventory.Items WHERE ItemCode = N'TVS-AP160' AND IsActive = 1);
    DECLARE @UnitId INT = (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1);
    DECLARE @PlId   INT = (SELECT TOP (1) Id FROM masterdata.PriceLists WHERE PriceListCode = N'PL-001' AND IsActive = 1);

    IF @ItemId IS NOT NULL AND @UnitId IS NOT NULL AND @PlId IS NOT NULL
    BEGIN
        DECLARE @NewId INT;
        EXEC masterdata.usp_UnitPrice_Create @BranchId = NULL, @ItemId = @ItemId, @ItemUnitId = @UnitId,
             @PriceListId = @PlId, @Price = 2500.0000, @IsActive = 1, @UserId = NULL, @NewId = @NewId OUTPUT;
        PRINT 'Seeded demo price: TVS-AP160 / PC / Retail USD / All Branches = 2,500.00 (history row written).';
    END
END
GO

-- ===== 13: Master Data - Parties =====

/* =====================================================================================
   Inventory_Shipment - 13: Master Data - Parties   (user story US-MD-007)

   ONE centralized party master (suppliers, clients, salesmen, employees) with MULTI-TYPE flags.

   Schema:  masterdata. Table: masterdata.Parties
   Procs:   masterdata.usp_Party_Search / _Get / _Lookup / _NextCode / _Create / _Update /
            _SetActive / _Delete
   Seeds:   permissions masterdata.parties.view / create / edit / delete (sort 520-550);
            supplier SUP-0001 "TVS Motor Company" when the table is empty.

   Design (agreed):
     - Types are four flags (IsSupplier / IsClient / IsSalesman / IsEmployee); at least one is set.
     - Party Code is auto-SUGGESTED from the first checked type (SUP-/CLI-/SAL-/EMP- + 4 digits),
       editable, unique, never renamed later.
     - Optional links: BranchId (active branch), UserId (security.Users - one party per user, for
       "current user is salesman X"), DefaultCurrencyId (suppliers), DefaultPriceListId (any party,
       whatever its types): the price list PRE-FILLED on invoices for this party, changeable there.
       Resolution on a sales document: party's default list -> company default (Retail USD).
     - Email format validated when entered; phone/mobile free text; no uniqueness on contacts.
     - A type cannot be REMOVED while the party is referenced in that role. Convention for future
       tables: name the FK column after the role - SupplierId / ClientId / SalesmanId / EmployeeId
       (a generic PartyId column blocks the removal of any type). The guard reads sys.foreign_keys,
       so it switches on automatically when purchase/sales tables arrive.
     - Delete only when nothing references the party (any FK) - else deactivate.

   Error numbers (read by the API):
     60000 validation   60001 Party Code already exists   60002 user already linked to another party
     60003 referenced - cannot delete   60004 concurrency   60005 type in use - cannot be removed
     60006 not found   60008 related master data missing/inactive (branch, price list, currency, user)

   Requires 01, 03, 06 (Branches), 08 (Currencies), 12 (Price Lists). Idempotent. SQL Server 2016 SP1+.
   ===================================================================================== */


IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'masterdata.Branches', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL OR OBJECT_ID(N'masterdata.PriceLists', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 01, 03, 06, 08 and 12 before this script.', 16, 1);
    RETURN;
END
GO

/* ------------------------------------------------------------------ 1. Table */

IF OBJECT_ID(N'masterdata.Parties', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Parties
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        PartyCode          NVARCHAR(20)      NOT NULL,
        PartyName          NVARCHAR(200)     NOT NULL,
        IsSupplier         BIT               NOT NULL CONSTRAINT DF_Parties_IsSupplier DEFAULT (0),
        IsClient           BIT               NOT NULL CONSTRAINT DF_Parties_IsClient   DEFAULT (0),
        IsSalesman         BIT               NOT NULL CONSTRAINT DF_Parties_IsSalesman DEFAULT (0),
        IsEmployee         BIT               NOT NULL CONSTRAINT DF_Parties_IsEmployee DEFAULT (0),
        BranchId           INT               NULL,
        ContactPerson      NVARCHAR(150)     NULL,
        Phone              NVARCHAR(50)      NULL,
        Mobile             NVARCHAR(50)      NULL,
        Email              NVARCHAR(150)     NULL,
        Address            NVARCHAR(500)     NULL,
        Country            NVARCHAR(2)       NULL,        -- ISO 3166-1 alpha-2
        TaxRegistrationNo  NVARCHAR(50)      NULL,
        Notes              NVARCHAR(1000)    NULL,
        UserId             INT               NULL,        -- linked application user (salesman / employee)
        DefaultPriceListId INT               NULL,        -- pre-filled on invoices, editable there
        DefaultCurrencyId  INT               NULL,        -- suppliers: currency used by default on purchases
        IsActive           BIT               NOT NULL CONSTRAINT DF_Parties_IsActive DEFAULT (1),
        CreatedAtUtc       DATETIME2(3)      NOT NULL CONSTRAINT DF_Parties_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy          INT               NULL,
        UpdatedAtUtc       DATETIME2(3)      NULL,
        UpdatedBy          INT               NULL,
        RowVersion         ROWVERSION        NOT NULL,
        CONSTRAINT PK_Parties PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Parties_PartyCode UNIQUE (PartyCode),
        CONSTRAINT CK_Parties_PartyCode_NotBlank CHECK (LEN(LTRIM(RTRIM(PartyCode))) > 0),
        CONSTRAINT CK_Parties_PartyName_NotBlank CHECK (LEN(LTRIM(RTRIM(PartyName))) > 0),
        CONSTRAINT CK_Parties_AtLeastOneType CHECK (IsSupplier = 1 OR IsClient = 1 OR IsSalesman = 1 OR IsEmployee = 1),
        CONSTRAINT FK_Parties_Branch        FOREIGN KEY (BranchId)           REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_Parties_User          FOREIGN KEY (UserId)             REFERENCES security.Users (Id),
        CONSTRAINT FK_Parties_PriceList     FOREIGN KEY (DefaultPriceListId) REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_Parties_Currency      FOREIGN KEY (DefaultCurrencyId)  REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_Parties_CreatedBy     FOREIGN KEY (CreatedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_Parties_UpdatedBy     FOREIGN KEY (UpdatedBy)          REFERENCES security.Users (Id)
    );

    -- One party per application user.
    CREATE UNIQUE NONCLUSTERED INDEX UX_Parties_UserId ON masterdata.Parties (UserId) WHERE UserId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Parties_PartyName ON masterdata.Parties (PartyName);
    CREATE NONCLUSTERED INDEX IX_Parties_Branch    ON masterdata.Parties (BranchId);
    CREATE NONCLUSTERED INDEX IX_Parties_Types     ON masterdata.Parties (IsSupplier, IsClient, IsSalesman, IsEmployee) INCLUDE (PartyCode, PartyName, IsActive);

    PRINT 'Created masterdata.Parties';
END
GO

-- Upgrade for databases created with the interim per-role version (ClientPriceListId / SalesmanPriceListId).
IF COL_LENGTH(N'masterdata.Parties', N'ClientPriceListId') IS NOT NULL
BEGIN
    EXEC sp_rename N'masterdata.Parties.ClientPriceListId', N'DefaultPriceListId', N'COLUMN';
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Parties_ClientPriceList')
        EXEC sp_rename N'masterdata.FK_Parties_ClientPriceList', N'FK_Parties_PriceList', N'OBJECT';
    PRINT 'Renamed ClientPriceListId -> DefaultPriceListId';
END
GO

IF COL_LENGTH(N'masterdata.Parties', N'SalesmanPriceListId') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Parties_SalesmanPriceList')
        ALTER TABLE masterdata.Parties DROP CONSTRAINT FK_Parties_SalesmanPriceList;
    ALTER TABLE masterdata.Parties DROP COLUMN SalesmanPriceListId;
    PRINT 'Dropped SalesmanPriceListId (single default price list per party)';
END
GO

/* ------------------------------------------------------------------ 2. Procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Search
    @Search        NVARCHAR(200) = NULL,   -- code, name, phone, mobile or email
    @PartyType     NVARCHAR(20)  = NULL,   -- Supplier | Client | Salesman | Employee | NULL = all
    @BranchId      INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PartyCode', -- PartyCode | PartyName | BranchName | Email | Phone | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @PartyType = NULLIF(LTRIM(RTRIM(@PartyType)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PartyCode', N'PartyName', N'BranchName', N'Email', N'Phone', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'PartyCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, b.BranchCode, b.BranchName, p.ContactPerson, p.Phone, p.Mobile, p.Email,
           p.Address, p.Country, p.TaxRegistrationNo, p.Notes,
           p.UserId, u.Username AS UserName, u.FullName AS UserFullName,
           p.DefaultPriceListId, pl.PriceListName AS DefaultPriceListName,
           p.DefaultCurrencyId, c.CurrencyCode AS DefaultCurrencyCode,
           p.IsActive, p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Parties p
    LEFT JOIN masterdata.Branches b    ON b.Id  = p.BranchId
    LEFT JOIN security.Users u         ON u.Id  = p.UserId
    LEFT JOIN masterdata.PriceLists pl ON pl.Id = p.DefaultPriceListId
    LEFT JOIN masterdata.Currencies c  ON c.Id  = p.DefaultCurrencyId
    WHERE (@Search IS NULL OR p.PartyCode LIKE N'%' + @Search + N'%' OR p.PartyName LIKE N'%' + @Search + N'%'
           OR p.Phone LIKE N'%' + @Search + N'%' OR p.Mobile LIKE N'%' + @Search + N'%' OR p.Email LIKE N'%' + @Search + N'%')
      AND (@PartyType IS NULL
           OR (@PartyType = N'Supplier' AND p.IsSupplier = 1)
           OR (@PartyType = N'Client'   AND p.IsClient   = 1)
           OR (@PartyType = N'Salesman' AND p.IsSalesman = 1)
           OR (@PartyType = N'Employee' AND p.IsEmployee = 1))
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@IsActive IS NULL OR p.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'PartyCode' THEN p.PartyCode WHEN N'PartyName' THEN p.PartyName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Email' THEN p.Email WHEN N'Phone' THEN p.Phone END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'PartyCode' THEN p.PartyCode WHEN N'PartyName' THEN p.PartyName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Email' THEN p.Email WHEN N'Phone' THEN p.Phone END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END DESC,
        p.PartyCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, b.BranchCode, b.BranchName, p.ContactPerson, p.Phone, p.Mobile, p.Email,
           p.Address, p.Country, p.TaxRegistrationNo, p.Notes,
           p.UserId, u.Username AS UserName, u.FullName AS UserFullName,
           p.DefaultPriceListId, pl.PriceListName AS DefaultPriceListName,
           p.DefaultCurrencyId, c.CurrencyCode AS DefaultCurrencyCode,
           p.IsActive, p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion
    FROM masterdata.Parties p
    LEFT JOIN masterdata.Branches b    ON b.Id  = p.BranchId
    LEFT JOIN security.Users u         ON u.Id  = p.UserId
    LEFT JOIN masterdata.PriceLists pl ON pl.Id = p.DefaultPriceListId
    LEFT JOIN masterdata.Currencies c  ON c.Id  = p.DefaultCurrencyId
    WHERE p.Id = @Id;
END
GO

-- Typed dropdown data for the other modules (purchase orders -> Supplier, invoices -> Client...).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_Lookup
    @PartyType  NVARCHAR(20)  = NULL,   -- Supplier | Client | Salesman | Employee | NULL = any
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @PartyType = NULLIF(LTRIM(RTRIM(@PartyType)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;
    IF @Top > 500 SET @Top = 500;

    SELECT TOP (@Top) p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, p.DefaultPriceListId, p.DefaultCurrencyId, p.UserId, p.IsActive
    FROM masterdata.Parties p
    WHERE (@ActiveOnly = 0 OR p.IsActive = 1 OR p.Id = @IncludeId)
      AND (@PartyType IS NULL
           OR (@PartyType = N'Supplier' AND p.IsSupplier = 1)
           OR (@PartyType = N'Client'   AND p.IsClient   = 1)
           OR (@PartyType = N'Salesman' AND p.IsSalesman = 1)
           OR (@PartyType = N'Employee' AND p.IsEmployee = 1)
           OR p.Id = @IncludeId)
      AND (@Search IS NULL OR p.PartyCode LIKE N'%' + @Search + N'%' OR p.PartyName LIKE N'%' + @Search + N'%')
    ORDER BY CASE WHEN p.PartyCode LIKE @Search + N'%' THEN 0 ELSE 1 END, p.PartyName;
END
GO

-- Suggested code from the first checked type: SUP-0001 / CLI-0001 / SAL-0001 / EMP-0001 (editable).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_NextCode
    @PartyType NVARCHAR(20)   -- Supplier | Client | Salesman | Employee
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Prefix NVARCHAR(4) =
        CASE @PartyType WHEN N'Supplier' THEN N'SUP-' WHEN N'Client' THEN N'CLI-'
                        WHEN N'Salesman' THEN N'SAL-' WHEN N'Employee' THEN N'EMP-' END;
    IF @Prefix IS NULL
        THROW 60000, 'Party type must be Supplier, Client, Salesman or Employee.', 1;

    DECLARE @Seq INT = 1, @Code NVARCHAR(20);
    SET @Code = @Prefix + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM masterdata.Parties WHERE PartyCode = @Code) AND @Seq < 100000
    BEGIN
        SET @Seq += 1;
        SET @Code = @Prefix + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), 4);
    END

    SELECT SuggestedCode = @Code;
END
GO

-- Shared validation (called by Create and Update).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_Validate
    @Id                 INT = NULL,       -- NULL when creating
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT, @IsClient BIT, @IsSalesman BIT, @IsEmployee BIT,
    @BranchId           INT,
    @Email              NVARCHAR(150),
    @UserId             INT,
    @DefaultPriceListId INT,
    @DefaultCurrencyId  INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @PartyCode IS NULL OR @PartyCode = N'' THROW 60000, 'Party Code is required.', 1;
    IF @PartyName IS NULL OR @PartyName = N'' THROW 60000, 'Party Name is required.', 1;
    IF ISNULL(@IsSupplier, 0) = 0 AND ISNULL(@IsClient, 0) = 0 AND ISNULL(@IsSalesman, 0) = 0 AND ISNULL(@IsEmployee, 0) = 0
        THROW 60000, 'At least one Party Type must be selected.', 1;
    IF @Email IS NOT NULL AND (@Email NOT LIKE N'%_@_%.__%' OR @Email LIKE N'% %')
        THROW 60000, 'Email address format is not valid.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 60008, 'Branch not found or inactive.', 1;
    IF @DefaultPriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @DefaultPriceListId AND IsActive = 1)
        THROW 60008, 'Default price list not found or inactive.', 1;
    IF @DefaultCurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @DefaultCurrencyId AND IsActive = 1)
        THROW 60008, 'Default currency not found or inactive.', 1;
    IF @UserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId)
        THROW 60008, 'Linked user not found.', 1;
    IF @UserId IS NOT NULL AND EXISTS (SELECT 1 FROM masterdata.Parties WHERE UserId = @UserId AND (@Id IS NULL OR Id <> @Id))
        THROW 60002, 'This user is already linked to another party.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Parties WHERE PartyCode = @PartyCode AND (@Id IS NULL OR Id <> @Id))
        THROW 60001, 'A party with this Party Code already exists.', 1;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Create
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT = 0,
    @IsClient           BIT = 0,
    @IsSalesman         BIT = 0,
    @IsEmployee         BIT = 0,
    @BranchId           INT            = NULL,
    @ContactPerson      NVARCHAR(150)  = NULL,
    @Phone              NVARCHAR(50)   = NULL,
    @Mobile             NVARCHAR(50)   = NULL,
    @Email              NVARCHAR(150)  = NULL,
    @Address            NVARCHAR(500)  = NULL,
    @Country            NVARCHAR(2)    = NULL,
    @TaxRegistrationNo  NVARCHAR(50)   = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL,
    @DefaultPriceListId INT            = NULL,
    @DefaultCurrencyId  INT            = NULL,
    @IsActive           BIT            = 1,
    @ActorUserId        INT            = NULL,   -- who is saving (CreatedBy)
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @PartyCode = LTRIM(RTRIM(@PartyCode));  SET @PartyName = LTRIM(RTRIM(@PartyName));
    SET @ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), N'');
    SET @Phone   = NULLIF(LTRIM(RTRIM(@Phone)), N'');   SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'');
    SET @Email   = NULLIF(LTRIM(RTRIM(@Email)), N'');   SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @Country = NULLIF(UPPER(LTRIM(RTRIM(@Country))), N'');
    SET @TaxRegistrationNo = NULLIF(LTRIM(RTRIM(@TaxRegistrationNo)), N'');
    SET @Notes   = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @IsSupplier = ISNULL(@IsSupplier, 0); SET @IsClient = ISNULL(@IsClient, 0);
    SET @IsSalesman = ISNULL(@IsSalesman, 0); SET @IsEmployee = ISNULL(@IsEmployee, 0);
    SET @IsActive = ISNULL(@IsActive, 1);

    EXEC masterdata.usp_Party_Validate NULL, @PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee,
         @BranchId, @Email, @UserId, @DefaultPriceListId, @DefaultCurrencyId;

    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, BranchId,
                                    ContactPerson, Phone, Mobile, Email, Address, Country, TaxRegistrationNo, Notes,
                                    UserId, DefaultPriceListId, DefaultCurrencyId, IsActive, CreatedBy)
    VALUES (@PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee, @BranchId,
            @ContactPerson, @Phone, @Mobile, @Email, @Address, @Country, @TaxRegistrationNo, @Notes,
            @UserId, @DefaultPriceListId, @DefaultCurrencyId, @IsActive, @ActorUserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- Returns 1 when the party is referenced in a given role. Convention: FK columns named
-- SupplierId / ClientId / SalesmanId / EmployeeId (role-specific) or PartyId (any role).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_IsReferencedAs
    @Id         INT,
    @Role       NVARCHAR(20),   -- Supplier | Client | Salesman | Employee | NULL = any reference at all
    @Referenced BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Referenced = 0;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Parties')
      AND (@Role IS NULL OR c.name LIKE @Role + N'%' OR c.name LIKE N'Party%');

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Update
    @Id                 INT,
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT = 0,
    @IsClient           BIT = 0,
    @IsSalesman         BIT = 0,
    @IsEmployee         BIT = 0,
    @BranchId           INT            = NULL,
    @ContactPerson      NVARCHAR(150)  = NULL,
    @Phone              NVARCHAR(50)   = NULL,
    @Mobile             NVARCHAR(50)   = NULL,
    @Email              NVARCHAR(150)  = NULL,
    @Address            NVARCHAR(500)  = NULL,
    @Country            NVARCHAR(2)    = NULL,
    @TaxRegistrationNo  NVARCHAR(50)   = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL,
    @DefaultPriceListId INT            = NULL,
    @DefaultCurrencyId  INT            = NULL,
    @IsActive           BIT            = 1,
    @RowVersion         BINARY(8)      = NULL,
    @ActorUserId        INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @PartyCode = LTRIM(RTRIM(@PartyCode));  SET @PartyName = LTRIM(RTRIM(@PartyName));
    SET @ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), N'');
    SET @Phone   = NULLIF(LTRIM(RTRIM(@Phone)), N'');   SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'');
    SET @Email   = NULLIF(LTRIM(RTRIM(@Email)), N'');   SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @Country = NULLIF(UPPER(LTRIM(RTRIM(@Country))), N'');
    SET @TaxRegistrationNo = NULLIF(LTRIM(RTRIM(@TaxRegistrationNo)), N'');
    SET @Notes   = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @IsSupplier = ISNULL(@IsSupplier, 0); SET @IsClient = ISNULL(@IsClient, 0);
    SET @IsSalesman = ISNULL(@IsSalesman, 0); SET @IsEmployee = ISNULL(@IsEmployee, 0);
    SET @IsActive = ISNULL(@IsActive, 1);

    DECLARE @WasSupplier BIT, @WasClient BIT, @WasSalesman BIT, @WasEmployee BIT;
    SELECT @WasSupplier = IsSupplier, @WasClient = IsClient, @WasSalesman = IsSalesman, @WasEmployee = IsEmployee
    FROM masterdata.Parties WHERE Id = @Id;
    IF @WasSupplier IS NULL
        THROW 60006, 'Party not found.', 1;

    EXEC masterdata.usp_Party_Validate @Id, @PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee,
         @BranchId, @Email, @UserId, @DefaultPriceListId, @DefaultCurrencyId;

    -- A type cannot be removed while the party is referenced in that role.
    DECLARE @Ref BIT;
    IF @WasSupplier = 1 AND @IsSupplier = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Supplier', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Supplier type cannot be removed: this party is used as a supplier in existing transactions.', 1;
    END
    IF @WasClient = 1 AND @IsClient = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Client', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Client type cannot be removed: this party is used as a client in existing transactions.', 1;
    END
    IF @WasSalesman = 1 AND @IsSalesman = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Salesman', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Salesman type cannot be removed: this party is used as a salesman in existing transactions.', 1;
    END
    IF @WasEmployee = 1 AND @IsEmployee = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Employee', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Employee type cannot be removed: this party is used as an employee in existing transactions.', 1;
    END

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 60004, 'This party was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.Parties
    SET PartyCode = @PartyCode, PartyName = @PartyName,
        IsSupplier = @IsSupplier, IsClient = @IsClient, IsSalesman = @IsSalesman, IsEmployee = @IsEmployee,
        BranchId = @BranchId, ContactPerson = @ContactPerson, Phone = @Phone, Mobile = @Mobile, Email = @Email,
        Address = @Address, Country = @Country, TaxRegistrationNo = @TaxRegistrationNo, Notes = @Notes,
        UserId = @UserId, DefaultPriceListId = @DefaultPriceListId, DefaultCurrencyId = @DefaultCurrencyId,
        IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @ActorUserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_SetActive
    @Id INT, @IsActive BIT, @ActorUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id)
        THROW 60006, 'Party not found.', 1;
    UPDATE masterdata.Parties SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @ActorUserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id)
        THROW 60006, 'Party not found.', 1;

    DECLARE @Ref BIT;
    EXEC masterdata.usp_Party_IsReferencedAs @Id, NULL, @Ref OUTPUT;
    IF @Ref = 1
        THROW 60003, 'This party cannot be deleted because it is referenced by existing transactions. You may deactivate the party instead.', 1;

    DELETE FROM masterdata.Parties WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 3. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.parties.view',   N'View parties',   N'Master Data', N'See the Parties list (suppliers, clients, salesmen, employees).', 520),
        (N'masterdata.parties.create', N'Create parties', N'Master Data', N'Add new parties.',                                                530),
        (N'masterdata.parties.edit',   N'Edit parties',   N'Master Data', N'Change parties and activate / deactivate them.',                 540),
        (N'masterdata.parties.delete', N'Delete parties', N'Master Data', N'Delete parties never referenced by transactions.',               550)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'masterdata.parties.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'masterdata.parties.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 4. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Parties)
BEGIN
    DECLARE @InrId INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE CurrencyCode = N'INR' AND IsActive = 1);
    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, Country, DefaultCurrencyId, IsActive, Notes)
    VALUES (N'SUP-0001', N'TVS Motor Company', 1, 0, 0, 0, N'IN', @InrId, 1, N'Principal supplier of motorcycles and spare parts.');
    PRINT 'Seeded party SUP-0001 TVS Motor Company (supplier).';
END
GO

-- ===== 14: Sales - Invoice import =====

/* =====================================================================================
   Inventory_Shipment - 14: Sales - Import Invoice Items from Excel   (user story US-SAL-002)

   New schema: sales. This script provides the VALIDATION ENGINE and the IMPORT AUDIT LOG.
   The Excel file is parsed by the API (ClosedXML) into rows; the rows are sent here as a
   table-valued parameter and validated in ONE round trip against the master data:
   items (by Item Code or Barcode), units & packaging, warehouses of the invoice branch, and
   the Unit Price List (branch-specific price -> All Branches price).

   Objects:
     sales.tvp_InvoiceImportRow             - table type (one Excel row)
     sales.usp_InvoiceImport_Validate       - returns every row with Status Valid | Warning | Error,
                                              a message, and the RESOLVED values (item, unit,
                                              warehouse, effective price, discount, expiry)
     sales.InvoiceImportLogs                - one row per import operation (audit)
     sales.usp_InvoiceImport_Log            - writes the audit row
     sales.usp_InvoiceImport_AttachInvoice  - links log rows to the invoice once it is saved
   Permissions: sales.invoices.import (run imports), sales.invoices.priceoverride (a manual
                Unit Price in the file is accepted instead of the system price), module "Sales".

   Validation rules (spec US-SAL-002):
     - Item Code / Barcode required; item must exist and be active (barcode also fixes the unit).
     - Quantity required, whole number > 0 (pieces).
     - Unit: if given must be configured for the item (unit type name or SKU); blank = the item's
       Sales Unit (base unit when none is flagged).
     - Warehouse: if given must exist, be active and belong to the invoice branch (code or name);
       blank = invoice header default warehouse.
     - Unit Price: blank = system price (branch -> all branches); given = accepted only when
       @AllowPriceOverride = 1, otherwise the system price is used with a Warning; no system price
       and no accepted manual price = Error.
     - Discount %: blank = 0; must be between 0 and @MaxDiscountPercent.
     - Expiry Date: unparseable = Error; in the past = Warning.
     - Status precedence: any Error -> Error; else any Warning -> Warning; else Valid.
   Consolidation of identical rows (rule 16) is done by the API after validation.

   Error numbers (header problems, read by the API): 61000 validation, 61008 branch / warehouse /
   price list missing or inactive, or warehouse not in the branch.

   Requires 06 (Branches), 07 (Warehouses), 11 (Items), 12 (Price Lists / Unit Prices).
   Idempotent. NOTE: a table type cannot be ALTERed - to change it, drop the procs using it first.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL OR OBJECT_ID(N'masterdata.UnitPrices', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 07, 11 and 12 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'sales') IS NULL
    EXEC (N'CREATE SCHEMA [sales] AUTHORIZATION [dbo];');
GO

/* ------------------------------------------------------------------ 1. Table type (one Excel row) */

IF TYPE_ID(N'sales.tvp_InvoiceImportRow') IS NULL
BEGIN
    CREATE TYPE sales.tvp_InvoiceImportRow AS TABLE
    (
        RowNumber       INT            NOT NULL PRIMARY KEY,   -- Excel row number (for messages)
        ItemRef         NVARCHAR(50)   NULL,                   -- Item Code or Barcode
        UnitName        NVARCHAR(50)   NULL,                   -- unit type name or SKU; NULL = sales unit
        WarehouseRef    NVARCHAR(150)  NULL,                   -- warehouse code or name; NULL = header default
        Quantity        DECIMAL(18,3)  NULL,                   -- parsed number (NULL when not numeric)
        RawQuantity     NVARCHAR(50)   NULL,                   -- original text when parsing failed
        UnitPrice       DECIMAL(18,4)  NULL,                   -- manual price (NULL = use system price)
        DiscountPercent DECIMAL(9,4)   NULL,                   -- NULL = 0
        ExpiryDate      DATE           NULL,
        RawExpiryDate   NVARCHAR(50)   NULL,                   -- original text when parsing failed
        Notes           NVARCHAR(300)  NULL
    );
    PRINT 'Created type sales.tvp_InvoiceImportRow';
END
GO

/* ------------------------------------------------------------------ 2. Audit log */

IF OBJECT_ID(N'sales.InvoiceImportLogs', N'U') IS NULL
BEGIN
    CREATE TABLE sales.InvoiceImportLogs
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        InvoiceId      INT            NULL,          -- set when the invoice is saved (no FK yet: invoices come with US-SAL-001)
        DraftReference NVARCHAR(50)   NULL,          -- client-side draft id until the invoice exists
        BranchId       INT            NOT NULL,
        WarehouseId    INT            NOT NULL,
        PriceListId    INT            NOT NULL,
        FileName       NVARCHAR(255)  NOT NULL,
        TotalRows      INT            NOT NULL,
        ImportedRows   INT            NOT NULL,
        WarningRows    INT            NOT NULL,
        RejectedRows   INT            NOT NULL,
        ImportedBy     INT            NULL,
        ImportedAtUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_InvoiceImportLogs_ImportedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_InvoiceImportLogs PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_InvoiceImportLogs_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_InvoiceImportLogs_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_InvoiceImportLogs_PriceList FOREIGN KEY (PriceListId) REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_InvoiceImportLogs_User      FOREIGN KEY (ImportedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_InvoiceImportLogs_Invoice ON sales.InvoiceImportLogs (InvoiceId);
    PRINT 'Created sales.InvoiceImportLogs';
END
GO

/* ------------------------------------------------------------------ 3. Validation */

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT,
    @AllowPriceOverride  BIT           = 0,     -- caller holds sales.invoices.priceoverride
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,   -- from configuration
    @Rows                sales.tvp_InvoiceImportRow READONLY
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Invoice branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the invoice branch.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            -- Item by code, or by a unit barcode (which also identifies the unit).
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            -- Unit: explicit name/SKU, else the barcode's unit, else the sales unit (base when none flagged).
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END, iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            -- Warehouse: explicit code/name, else the invoice header default.
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            -- System price: branch-specific first, then All Branches (active prices only).
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               -- Errors (first one wins in the message, all block the row)
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               -- Warnings
               Warn1 = CASE WHEN x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.' END
        FROM resolved x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice ELSE j.SystemPrice END,
           PriceSource = CASE WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ------------------------------------------------------------------ 4. Audit procedures */

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Log
    @BranchId       INT,
    @WarehouseId    INT,
    @PriceListId    INT,
    @FileName       NVARCHAR(255),
    @TotalRows      INT,
    @ImportedRows   INT,
    @WarningRows    INT,
    @RejectedRows   INT,
    @DraftReference NVARCHAR(50) = NULL,
    @InvoiceId      INT          = NULL,
    @ImportedBy     INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 61000, 'File name is required.', 1;

    INSERT INTO sales.InvoiceImportLogs (InvoiceId, DraftReference, BranchId, WarehouseId, PriceListId, FileName,
                                         TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
    VALUES (@InvoiceId, @DraftReference, @BranchId, @WarehouseId, @PriceListId, LTRIM(RTRIM(@FileName)),
            ISNULL(@TotalRows, 0), ISNULL(@ImportedRows, 0), ISNULL(@WarningRows, 0), ISNULL(@RejectedRows, 0), @ImportedBy);
    SET @NewId = SCOPE_IDENTITY();
END
GO

-- Called by the invoice save (US-SAL-001) to attach the import logs of a draft to the saved invoice.
CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_AttachInvoice
    @DraftReference NVARCHAR(50),
    @InvoiceId      INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sales.InvoiceImportLogs SET InvoiceId = @InvoiceId
    WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;
END
GO

/* ------------------------------------------------------------------ 5. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'sales.invoices.import',        N'Import invoice items',  N'Sales', N'Import invoice lines from an Excel file.',                        600),
        (N'sales.invoices.priceoverride', N'Override selling price', N'Sales', N'Accept a manual unit price instead of the price list price.',   610)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code IN (N'sales.invoices.import', N'sales.invoices.priceoverride')
  AND r.IsSystem = 1
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- ===== 15: Inventory documents + stock ledger =====

/* =====================================================================================
   Inventory_Shipment - 15: Inventory In / Out documents + Stock Movements ledger
   (first document family; skeleton shared by the future Purchase and Sales families)

   Objects (schema inventory unless noted):
     DocumentTypes            - CONFIGURATION of every document kind in the system (code, family,
                                stock direction, numbering prefix/sequence, number at draft or at post,
                                reason required). Seeded with the 8 agreed types.
     StockReasons             - reasons for Inventory In / Out (opening balance, correction, damage...)
     StockMovements           - THE LEDGER: every posted document of any family writes signed base-unit
                                quantities here; Stock Balance / Movement / Shortage read only this table.
     fn_StockOnHand, vw_StockBalance
     StockDocuments / StockDocumentLines / StockDocumentFiles / StockDocumentAudit
     tvp_StockDocumentLine, usp_StockDocument_Search / _Get / _Save / _Post / _Cancel / _Delete,
     usp_StockDocumentFile_Add / _Get / _Delete, usp_DocumentType_List / _NextNumber, usp_StockReason_Lookup
     inventory.usp_Item_Search / usp_Item_Get  - RE-CREATED: OnHand / LastCost / AverageCost now come from the ledger
     sales.usp_InvoiceImport_Validate          - RE-CREATED: @PriceListId optional (stock documents import
                                                 quantities + costs without a price list)

   Document lifecycle: Draft (editable, no stock effect) -> Posted (stock movements written, read-only)
                       -> Cancelled (reversal movements written). Drafts may be deleted; posted never.
   Quantities are pieces; lines store Quantity in the chosen unit + a snapshot of PackingFormula;
   the ledger stores QuantityBase = Quantity x PackingFormula (signed by the type's StockDirection).
   Costs: Inventory In lines carry a Unit Cost in the BASE currency (per unit); the ledger stores the
   cost per base unit. Inventory Out lines take the current average cost automatically.
   Numbering: DocumentTypes.NumberOnPost = 0 -> number assigned at first save (drafts get a number);
              = 1 -> drafts show DRAFT and the number is assigned when posting (gapless).

   Error numbers (read by the API):
     62000 validation (incl. per-line messages)   62004 concurrency   62005 document is not a draft
     62006 not found   62007 insufficient stock   62008 related master data missing/inactive
     62009 document has no lines   62010 invalid status transition (already posted / cancelled)

   Requires 07 (Warehouses), 08 (Currencies), 11 (Items), 12 (Price lists), 14 (Import engine).
   Idempotent. Table types cannot be altered - drop dependent procs first if you change one.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL OR OBJECT_ID(N'masterdata.Warehouses', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL OR OBJECT_ID(N'sales.usp_InvoiceImport_Validate', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 07, 08, 11, 12 and 14 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Document type configuration */

IF OBJECT_ID(N'inventory.DocumentTypes', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.DocumentTypes
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        Code           NVARCHAR(20)  NOT NULL,     -- INV_IN, INV_OUT, PO, PINV, PRET, SO, SINV, SRET
        Name           NVARCHAR(100) NOT NULL,
        Family         NVARCHAR(20)  NOT NULL,     -- Inventory | Purchase | Sales
        StockDirection SMALLINT      NOT NULL,     -- +1 adds stock, -1 removes, 0 no effect (orders)
        NumberPrefix   NVARCHAR(10)  NOT NULL,
        NextNumber     INT           NOT NULL CONSTRAINT DF_DocumentTypes_NextNumber DEFAULT (1),
        NumberLength   TINYINT       NOT NULL CONSTRAINT DF_DocumentTypes_NumberLength DEFAULT (6),
        NumberOnPost   BIT           NOT NULL CONSTRAINT DF_DocumentTypes_NumberOnPost DEFAULT (0),
        RequiresReason BIT           NOT NULL CONSTRAINT DF_DocumentTypes_RequiresReason DEFAULT (0),
        IsActive       BIT           NOT NULL CONSTRAINT DF_DocumentTypes_IsActive DEFAULT (1),
        UpdatedAtUtc   DATETIME2(3)  NULL,
        UpdatedBy      INT           NULL,
        RowVersion     ROWVERSION    NOT NULL,
        CONSTRAINT PK_DocumentTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_DocumentTypes_Code UNIQUE (Code),
        CONSTRAINT CK_DocumentTypes_Family CHECK (Family IN (N'Inventory', N'Purchase', N'Sales')),
        CONSTRAINT CK_DocumentTypes_Direction CHECK (StockDirection IN (-1, 0, 1)),
        CONSTRAINT CK_DocumentTypes_NumberLength CHECK (NumberLength BETWEEN 3 AND 10)
    );
    PRINT 'Created inventory.DocumentTypes';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES
    (N'INV_IN',  N'Inventory In',     N'Inventory',  1, N'IN-',   0, 1),
    (N'INV_OUT', N'Inventory Out',    N'Inventory', -1, N'OUT-',  0, 1),
    (N'PO',      N'Purchase Order',   N'Purchase',   0, N'PO-',   0, 0),
    (N'PINV',    N'Purchase Invoice', N'Purchase',   1, N'PINV-', 1, 0),
    (N'PRET',    N'Purchase Return',  N'Purchase',  -1, N'PRET-', 1, 0),
    (N'SO',      N'Sales Order',      N'Sales',      0, N'SO-',   0, 0),
    (N'SINV',    N'Sales Invoice',    N'Sales',     -1, N'INV-',  1, 0),
    (N'SRET',    N'Sales Return',     N'Sales',      1, N'SRET-', 1, 0)
) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

-- Atomic next number for a document type: prefix + zero-padded sequence (IN-000001).
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Taken TABLE (Prefix NVARCHAR(10), Number INT, Len TINYINT);

    UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
    SET NextNumber = NextNumber + 1
    OUTPUT deleted.NumberPrefix, deleted.NextNumber, deleted.NumberLength INTO @Taken
    WHERE Code = @Code AND IsActive = 1;

    IF NOT EXISTS (SELECT 1 FROM @Taken)
        THROW 62008, 'Document type not found or inactive.', 1;

    SELECT @DocumentNumber = Prefix + RIGHT(REPLICATE(N'0', Len) + CAST(Number AS NVARCHAR(10)), Len) FROM @Taken;
END
GO

/* ================================================================== 2. Stock reasons */

IF OBJECT_ID(N'inventory.StockReasons', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockReasons
    (
        Id         INT IDENTITY(1,1) NOT NULL,
        ReasonCode NVARCHAR(20)  NOT NULL,
        ReasonName NVARCHAR(100) NOT NULL,
        AppliesTo  NVARCHAR(10)  NOT NULL,   -- In | Out | Both
        IsActive   BIT           NOT NULL CONSTRAINT DF_StockReasons_IsActive DEFAULT (1),
        CONSTRAINT PK_StockReasons PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_StockReasons_Code UNIQUE (ReasonCode),
        CONSTRAINT CK_StockReasons_AppliesTo CHECK (AppliesTo IN (N'In', N'Out', N'Both'))
    );
    PRINT 'Created inventory.StockReasons';
END
GO

MERGE inventory.StockReasons AS t
USING (VALUES
    (N'OPENING',  N'Opening Balance',        N'In'),
    (N'ADJ_IN',   N'Stock Correction (+)',   N'In'),
    (N'FOUND',    N'Found / Surplus',        N'In'),
    (N'TRF_IN',   N'Transfer In',            N'In'),
    (N'RET_STOCK',N'Returned to Stock',      N'In'),
    (N'ADJ_OUT',  N'Stock Correction (-)',   N'Out'),
    (N'DAMAGED',  N'Damaged',                N'Out'),
    (N'LOST',     N'Lost / Stolen',          N'Out'),
    (N'TRF_OUT',  N'Transfer Out',           N'Out'),
    (N'INT_USE',  N'Internal Use',           N'Out')
) AS s (ReasonCode, ReasonName, AppliesTo)
ON t.ReasonCode = s.ReasonCode
WHEN NOT MATCHED BY TARGET THEN INSERT (ReasonCode, ReasonName, AppliesTo) VALUES (s.ReasonCode, s.ReasonName, s.AppliesTo);
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockReason_Lookup
    @Direction SMALLINT = NULL,    -- 1 = In, -1 = Out, NULL = all
    @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ReasonCode, ReasonName, AppliesTo, IsActive
    FROM inventory.StockReasons
    WHERE (IsActive = 1 OR Id = @IncludeId)
      AND (@Direction IS NULL OR AppliesTo = N'Both'
           OR (@Direction = 1 AND AppliesTo = N'In') OR (@Direction = -1 AND AppliesTo = N'Out'))
    ORDER BY ReasonName;
END
GO

/* ================================================================== 3. Stock movements ledger */

IF OBJECT_ID(N'inventory.StockMovements', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockMovements
    (
        Id               BIGINT IDENTITY(1,1) NOT NULL,
        MovementDate     DATETIME2(3)  NOT NULL,      -- effective date (document date + posting time)
        ItemId           INT           NOT NULL,
        WarehouseId      INT           NOT NULL,
        BranchId         INT           NOT NULL,
        QuantityBase     INT           NOT NULL,      -- signed, in BASE units (+ in / - out)
        UnitCostBase     DECIMAL(18,6) NULL,          -- cost per base unit, base currency
        DocumentFamily   NVARCHAR(20)  NOT NULL,      -- Inventory | Purchase | Sales
        DocumentTypeCode NVARCHAR(20)  NOT NULL,
        DocumentId       INT           NOT NULL,
        DocumentLineId   INT           NOT NULL,
        DocumentNumber   NVARCHAR(30)  NOT NULL,
        ReasonCode       NVARCHAR(20)  NULL,
        ExpiryDate       DATE          NULL,
        IsReversal       BIT           NOT NULL CONSTRAINT DF_StockMovements_IsReversal DEFAULT (0),
        CreatedAtUtc     DATETIME2(3)  NOT NULL CONSTRAINT DF_StockMovements_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT           NULL,
        CONSTRAINT PK_StockMovements PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_StockMovements_Qty CHECK (QuantityBase <> 0),
        CONSTRAINT FK_StockMovements_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_StockMovements_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_StockMovements_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_StockMovements_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockMovements_ItemWarehouseDate ON inventory.StockMovements (ItemId, WarehouseId, MovementDate) INCLUDE (QuantityBase, UnitCostBase);
    CREATE NONCLUSTERED INDEX IX_StockMovements_WarehouseDate     ON inventory.StockMovements (WarehouseId, MovementDate) INCLUDE (ItemId, QuantityBase);
    CREATE NONCLUSTERED INDEX IX_StockMovements_Document          ON inventory.StockMovements (DocumentFamily, DocumentId);
    PRINT 'Created inventory.StockMovements';
END
GO

-- On-hand in BASE units for an item (optionally in one warehouse).
CREATE OR ALTER FUNCTION inventory.fn_StockOnHand (@ItemId INT, @WarehouseId INT)
RETURNS INT
AS
BEGIN
    RETURN ISNULL((SELECT SUM(QuantityBase) FROM inventory.StockMovements
                   WHERE ItemId = @ItemId AND (@WarehouseId IS NULL OR WarehouseId = @WarehouseId)), 0);
END
GO

-- Weighted average cost per base unit of all receipts (positive, non-reversal movements).
CREATE OR ALTER FUNCTION inventory.fn_AverageCost (@ItemId INT)
RETURNS DECIMAL(18,6)
AS
BEGIN
    RETURN (SELECT CASE WHEN SUM(QuantityBase) > 0 THEN SUM(QuantityBase * ISNULL(UnitCostBase, 0)) / SUM(QuantityBase) END
            FROM inventory.StockMovements
            WHERE ItemId = @ItemId AND QuantityBase > 0 AND IsReversal = 0);
END
GO

CREATE OR ALTER VIEW inventory.vw_StockBalance
AS
    SELECT m.ItemId, i.ItemCode, i.ItemName, m.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId,
           OnHandBase = SUM(m.QuantityBase), LastMovementAtUtc = MAX(m.MovementDate)
    FROM inventory.StockMovements m
    INNER JOIN inventory.Items i ON i.Id = m.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    GROUP BY m.ItemId, i.ItemCode, i.ItemName, m.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId;
GO

/* ================================================================== 4. Stock documents (Inventory In / Out) */

IF OBJECT_ID(N'inventory.StockDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocuments
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId INT            NOT NULL,
        DocumentNumber NVARCHAR(30)   NULL,          -- NULL while a draft of a NumberOnPost type
        DocumentDate   DATE           NOT NULL,
        BranchId       INT            NOT NULL,
        WarehouseId    INT            NOT NULL,      -- default warehouse (lines may differ)
        ReasonId       INT            NULL,
        ReferenceNo    NVARCHAR(100)  NULL,          -- external reference (delivery note, BL, count sheet...)
        CurrencyId     INT            NOT NULL,      -- base currency for stock documents
        ExchangeRate   DECIMAL(18,6)  NOT NULL CONSTRAINT DF_StockDocuments_Rate DEFAULT (1),
        Notes          NVARCHAR(1000) NULL,
        Status         TINYINT        NOT NULL CONSTRAINT DF_StockDocuments_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled
        TotalItems     INT            NOT NULL CONSTRAINT DF_StockDocuments_TotalItems DEFAULT (0),
        TotalQuantity  INT            NOT NULL CONSTRAINT DF_StockDocuments_TotalQuantity DEFAULT (0),   -- base units
        TotalCost      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_StockDocuments_TotalCost DEFAULT (0),
        PostedAtUtc    DATETIME2(3)   NULL,
        PostedBy       INT            NULL,
        CancelledAtUtc DATETIME2(3)   NULL,
        CancelledBy    INT            NULL,
        CancelReason   NVARCHAR(300)  NULL,
        CreatedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_StockDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT            NULL,
        UpdatedAtUtc   DATETIME2(3)   NULL,
        UpdatedBy      INT            NULL,
        RowVersion     ROWVERSION     NOT NULL,
        CONSTRAINT PK_StockDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_StockDocuments_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT FK_StockDocuments_Type      FOREIGN KEY (DocumentTypeId) REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_StockDocuments_Branch    FOREIGN KEY (BranchId)       REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_StockDocuments_Warehouse FOREIGN KEY (WarehouseId)    REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_StockDocuments_Reason    FOREIGN KEY (ReasonId)       REFERENCES inventory.StockReasons (Id),
        CONSTRAINT FK_StockDocuments_Currency  FOREIGN KEY (CurrencyId)     REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_StockDocuments_CreatedBy FOREIGN KEY (CreatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_StockDocuments_UpdatedBy FOREIGN KEY (UpdatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_StockDocuments_PostedBy  FOREIGN KEY (PostedBy)       REFERENCES security.Users (Id),
        CONSTRAINT FK_StockDocuments_CancelledBy FOREIGN KEY (CancelledBy)  REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_StockDocuments_Number ON inventory.StockDocuments (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_StockDocuments_TypeDate   ON inventory.StockDocuments (DocumentTypeId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_StockDocuments_TypeStatus ON inventory.StockDocuments (DocumentTypeId, Status);
    PRINT 'Created inventory.StockDocuments';
END
GO

IF OBJECT_ID(N'inventory.StockDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocumentLines
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        DocumentId     INT           NOT NULL,
        LineNumber         INT           NOT NULL,
        ItemId         INT           NOT NULL,
        ItemUnitId     INT           NOT NULL,
        WarehouseId    INT           NOT NULL,
        ExpiryDate     DATE          NULL,
        Quantity       INT           NOT NULL,          -- in the chosen unit
        PackingFormula INT           NOT NULL,          -- snapshot from the item unit at save time
        QuantityBase   AS (Quantity * PackingFormula) PERSISTED,
        UnitCost       DECIMAL(18,4) NOT NULL CONSTRAINT DF_StockDocumentLines_UnitCost DEFAULT (0),   -- per unit, base currency
        LineTotal      AS (CONVERT(DECIMAL(18,2), Quantity * UnitCost)) PERSISTED,
        Notes          NVARCHAR(300) NULL,
        SourceLineId   INT           NULL,              -- family pattern (conversions) - unused for stock docs
        CONSTRAINT PK_StockDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_StockDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT CK_StockDocumentLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_StockDocumentLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_StockDocumentLines_Cost CHECK (UnitCost >= 0),
        CONSTRAINT FK_StockDocumentLines_Document  FOREIGN KEY (DocumentId)  REFERENCES inventory.StockDocuments (Id),
        CONSTRAINT FK_StockDocumentLines_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_StockDocumentLines_ItemUnit  FOREIGN KEY (ItemUnitId)  REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_StockDocumentLines_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockDocumentLines_Document ON inventory.StockDocumentLines (DocumentId);
    CREATE NONCLUSTERED INDEX IX_StockDocumentLines_Item     ON inventory.StockDocumentLines (ItemId);
    PRINT 'Created inventory.StockDocumentLines';
END
GO

IF OBJECT_ID(N'inventory.StockDocumentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocumentFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        DocumentId   INT            NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_StockDocumentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_StockDocumentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_StockDocumentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_StockDocumentFiles_Document  FOREIGN KEY (DocumentId) REFERENCES inventory.StockDocuments (Id),
        CONSTRAINT FK_StockDocumentFiles_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockDocumentFiles_Document ON inventory.StockDocumentFiles (DocumentId);
    PRINT 'Created inventory.StockDocumentFiles';
END
GO

IF OBJECT_ID(N'inventory.StockDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.StockDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Posted | Cancelled | Deleted | FileAdded | FileDeleted
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_StockDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_StockDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_StockDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_StockDocumentAudit_Document ON inventory.StockDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created inventory.StockDocumentAudit';
END
GO

IF TYPE_ID(N'inventory.tvp_StockDocumentLine') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_StockDocumentLine AS TABLE
    (
        LineNumber      INT           NOT NULL PRIMARY KEY,
        ItemId      INT           NOT NULL,
        ItemUnitId  INT           NOT NULL,
        WarehouseId INT           NOT NULL,
        ExpiryDate  DATE          NULL,
        Quantity    INT           NOT NULL,
        UnitCost    DECIMAL(18,4) NULL,       -- NULL = 0 for In; ignored for Out (average cost is used)
        Notes       NVARCHAR(300) NULL
    );
    PRINT 'Created type inventory.tvp_StockDocumentLine';
END
GO

/* ------------------------------------------------------------------ 4a. Search / Get */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,   -- INV_IN | INV_OUT | NULL = both
    @Search           NVARCHAR(100) = NULL,  -- number, reference or notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @Status           TINYINT      = NULL,   -- 1 Draft | 2 Posted | 3 Cancelled
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | BranchName | WarehouseName | Status | TotalCost | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'BranchName', N'WarehouseName', N'Status', N'TotalCost', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.ReasonId, r.ReasonName, d.ReferenceNo, c.CurrencyCode, d.Status,
           d.TotalItems, d.TotalQuantity, d.TotalCost,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.StockDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN inventory.StockReasons r   ON r.Id = d.ReasonId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Inventory'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.ReferenceNo LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'BranchName' THEN b.BranchName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'BranchName' THEN b.BranchName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalCost' THEN d.TotalCost END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalCost' THEN d.TotalCost END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: header, lines, file metadata, audit trail.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchCode, b.BranchName,
           d.WarehouseId, w.WarehouseCode, w.WarehouseName, d.ReasonId, r.ReasonCode, r.ReasonName,
           d.ReferenceNo, d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.TotalCost,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM inventory.StockDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN inventory.StockReasons r   ON r.Id = d.ReasonId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate, l.Quantity, l.QuantityBase,
           l.UnitCost, l.LineTotal, l.Notes, l.SourceLineId,
           OnHandBase = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId)
    FROM inventory.StockDocumentLines l
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM inventory.StockDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.StockDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ------------------------------------------------------------------ 4b. Validation helper (header + lines) */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT;
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 62008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END
GO

/* ------------------------------------------------------------------ 4c. Save (create or update a DRAFT) */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Save
    @Id               INT            = NULL,   -- NULL = create
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT,
    @ReasonId         INT            = NULL,
    @ReferenceNo      NVARCHAR(100)  = NULL,
    @Notes            NVARCHAR(1000) = NULL,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @RowVersion       BINARY(8)      = NULL,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT;
    EXEC inventory.usp_StockDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 62000, 'The document type cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT;

            INSERT INTO inventory.StockDocuments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, WarehouseId, ReasonId,
                                                  ReferenceNo, CurrencyId, ExchangeRate, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @ReferenceNo, @CurrencyId, 1, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.StockDocuments
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, ReasonId = @ReasonId,
                ReferenceNo = @ReferenceNo, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO inventory.StockDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, UnitCost, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               CASE WHEN @Direction = -1 THEN ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * iu.PackingFormula ELSE ISNULL(l.UnitCost, 0) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId;

        UPDATE d SET TotalItems = x.Items, TotalQuantity = x.Qty, TotalCost = x.Cost
        FROM inventory.StockDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty, ISNULL(SUM(LineTotal), 0) AS Cost
                     FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4d. Post (write the ledger) */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeId INT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @NumberOnPost BIT,
                @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);

        SELECT @Status = d.Status, @TypeId = d.DocumentTypeId, @TypeCode = dt.Code, @Direction = dt.StockDirection,
               @NumberOnPost = dt.NumberOnPost, @Number = d.DocumentNumber, @DocumentDate = d.DocumentDate,
               @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        -- Masters must still be valid at posting time.
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        -- Outgoing documents cannot exceed the stock on hand per item + warehouse.
        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4e. Cancel (reversal) / Delete draft */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 62000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT, @Number NVARCHAR(30), @TypeCode NVARCHAR(20), @BranchId INT, @ReasonCode NVARCHAR(20);
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @Number = d.DocumentNumber, @TypeCode = dt.Code, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 2 THROW 62010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Cancelling an incoming document removes stock again: it must still be there.
        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Inventory' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE inventory.StockDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 62006, 'Document not found.', 1;
    IF @Status <> 1 THROW 62005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM inventory.StockDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4f. Attachments */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @DocumentId) THROW 62006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 62000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 62000, 'The file is empty.', 1;

    INSERT INTO inventory.StockDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM inventory.StockDocumentFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM inventory.StockDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 62006, 'File not found.', 1;
    DELETE FROM inventory.StockDocumentFiles WHERE Id = @Id;
    INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 5. Items: real On Hand / costs from the ledger */

CREATE OR ALTER PROCEDURE inventory.usp_Item_Search
    @Search             NVARCHAR(200) = NULL,
    @ItemFamilyId       INT           = NULL,
    @BrandId            INT           = NULL,
    @DefaultWarehouseId INT           = NULL,
    @IsActive           BIT           = NULL,
    @IsBivac            BIT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'ItemCode',
    @SortDirection      NVARCHAR(4)   = N'ASC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BrandName', N'FamilyName', N'WarehouseName', N'IsActive', N'CreatedAtUtc', N'OnHand')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           bu.SkuCode AS BaseUnitSku, ut.UnitTypeName AS BaseUnitName,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           i.CreatedAtUtc, i.CreatedBy, i.UpdatedAtUtc, i.UpdatedBy, i.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b        ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN inventory.ItemUnits bu     ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes ut    ON ut.Id = bu.UnitTypeId
    WHERE (@Search IS NULL
           OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u
                      WHERE u.ItemId = i.Id AND (u.SkuCode LIKE N'%' + @Search + N'%' OR u.Barcode LIKE N'%' + @Search + N'%')))
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@DefaultWarehouseId IS NULL OR i.DefaultWarehouseId = @DefaultWarehouseId)
      AND (@IsActive IS NULL OR i.IsActive = @IsActive)
      AND (@IsBivac IS NULL OR i.IsBivac = @IsBivac)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END DESC,
        i.ItemCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           LastCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                       WHERE m.ItemId = i.Id AND m.QuantityBase > 0 AND m.IsReversal = 0 ORDER BY m.MovementDate DESC, m.Id DESC),
           AverageCost = CAST(inventory.fn_AverageCost(i.Id) AS DECIMAL(18,2)),
           LastPurchaseCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                               WHERE m.ItemId = i.Id AND m.DocumentFamily = N'Purchase' AND m.QuantityBase > 0 AND m.IsReversal = 0
                               ORDER BY m.MovementDate DESC, m.Id DESC),
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 6. Import engine: price list optional (stock documents) */

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = stock document: no pricing, Unit Price column = unit cost (optional)
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the selected branch.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE WHEN @PriceListId IS NULL THEN CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END       -- stock docs: base unit first
                          ELSE CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END END, iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @PriceListId IS NOT NULL AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.' END
        FROM resolved x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ================================================================== 7. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'inventory.stockin.view',     N'View Inventory In',    N'Inventory', N'See Inventory In documents.',                         700),
        (N'inventory.stockin.create',   N'Create Inventory In',  N'Inventory', N'Create and edit draft Inventory In documents.',       710),
        (N'inventory.stockin.post',     N'Post Inventory In',    N'Inventory', N'Post Inventory In documents (adds stock).',           720),
        (N'inventory.stockin.cancel',   N'Cancel Inventory In',  N'Inventory', N'Cancel posted Inventory In documents (reversal).',    730),
        (N'inventory.stockin.delete',   N'Delete Inventory In',  N'Inventory', N'Delete draft Inventory In documents.',                740),
        (N'inventory.stockout.view',    N'View Inventory Out',   N'Inventory', N'See Inventory Out documents.',                        760),
        (N'inventory.stockout.create',  N'Create Inventory Out', N'Inventory', N'Create and edit draft Inventory Out documents.',      770),
        (N'inventory.stockout.post',    N'Post Inventory Out',   N'Inventory', N'Post Inventory Out documents (removes stock).',       780),
        (N'inventory.stockout.cancel',  N'Cancel Inventory Out', N'Inventory', N'Cancel posted Inventory Out documents (reversal).',   790),
        (N'inventory.stockout.delete',  N'Delete Inventory Out', N'Inventory', N'Delete draft Inventory Out documents.',               800),
        (N'inventory.documenttypes.manage', N'Manage document types', N'Configuration', N'Change numbering and behaviour of document types.', 900)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'inventory.stockin.%' OR p.Code LIKE N'inventory.stockout.%' OR p.Code = N'inventory.documenttypes.manage')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'inventory.stockin.view', N'inventory.stockout.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- ===== 17: Sales documents =====

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 17: SALES document family (Sales Invoice first; Sales Order / Return later)

   One header table + one lines table for the whole Sales family, discriminated by the document type
   (inventory.DocumentTypes: SO = Sales Order (no stock effect), SINV = Sales Invoice (stock -1),
   SRET = Sales Return (stock +1)). Only SINV is exposed by the API / page now; the procedures are
   already generic (they read StockDirection from the configuration table).

   Objects (schema sales):
     SalesDocuments / SalesDocumentLines / SalesDocumentFiles / SalesDocumentAudit
     tvp_SalesDocumentLine
     usp_SalesDocument_Search / _Get / _ValidateInput / _Save / _Post / _Cancel / _Delete
     usp_SalesDocumentFile_Add / _Get / _Delete
     usp_SalesDocument_ResolveRate       - exchange rate the page shows before saving
     InvoiceImportLogs                   - InvoiceId is now a real FK to SalesDocuments; PriceListId nullable
                                           (stock-mode imports); usp_InvoiceImport_Log RE-CREATED (same
                                           signature, @PriceListId NULL allowed, audit row on the invoice)

   Business rules
     - Client = a party flagged Client (active); Salesman = a party flagged Salesman (optional).
     - Price List is required; the invoice CURRENCY is the price list currency (snapshot on the header).
     - Exchange rate: 1 base currency = Rate x invoice currency, taken from masterdata.fn_GetRate for the
       chosen RateType (1 Official default, 2 NonOfficial, 3 Market) at the document date; the user may
       override it (@ExchangeRate); base currency -> 1. Amounts are stored in the invoice currency and the
       base-currency equivalent (Amount / Rate) is stored beside them for reporting.
     - Line prices: when the caller has NO price-override permission (@AllowPriceOverride = 0) the line
       price is ALWAYS the price list price (fn_GetUnitPrice: branch price -> all-branches price); a line
       without any price list price is refused (64011 NO_PRICE). With the permission, a manual price is kept
       (PriceSource = Manual when it differs from the price list price).
     - Discount % per line between 0 and @MaxDiscountPercent (configuration Sales:MaxDiscountPercent).
     - Lines store Quantity in the chosen unit + PackingFormula snapshot; LineTotal = Qty x Price x (1 - Disc%).
     - Lifecycle: Draft (editable) -> Posted (SINV: stock movements written, COGS snapshot per line from the
       average cost, number INV-000001 assigned) -> Cancelled (reversal movements). Drafts can be deleted.
     - Posting an invoice needs enough stock per item + warehouse (64007 INSUFFICIENT_STOCK).
     - Excel import: the wizard logs every import (sales.InvoiceImportLogs); Save links the logs written
       under @DraftReference to the invoice (usp_InvoiceImport_AttachInvoice).

   Error numbers (read by the API):
     64000 validation ("Line N: ..." for line problems)   64004 concurrency   64005 not a draft
     64006 not found   64007 insufficient stock   64008 master data missing / inactive / no exchange rate
     64009 no lines   64010 invalid status transition   64011 no selling price for a line
   Permissions (module Sales): sales.invoices.view / create / post / cancel / delete (620-660).
     (sales.invoices.import 600 and sales.invoices.priceoverride 610 already exist - script 14.)

   Requires 06, 07, 08, 11, 12, 13, 14, 15. Idempotent. Table types cannot be altered - drop the procs first.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.DocumentTypes', N'U') IS NULL OR OBJECT_ID(N'inventory.StockMovements', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Parties', N'U') IS NULL OR OBJECT_ID(N'masterdata.PriceLists', N'U') IS NULL
   OR OBJECT_ID(N'sales.InvoiceImportLogs', N'U') IS NULL OR OBJECT_ID(N'masterdata.fn_GetRate', N'FN') IS NULL
BEGIN
    RAISERROR ('Run scripts 08, 12, 13, 14 and 15 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'sales.SalesDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocuments
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId   INT            NOT NULL,     -- SO | SINV | SRET (inventory.DocumentTypes, Family = Sales)
        DocumentNumber   NVARCHAR(30)   NULL,         -- NULL while a draft of a NumberOnPost type (SINV)
        DocumentDate     DATE           NOT NULL,
        DueDate          DATE           NULL,
        BranchId         INT            NOT NULL,
        WarehouseId      INT            NOT NULL,     -- default warehouse (lines may differ)
        ClientId         INT            NOT NULL,     -- masterdata.Parties (IsClient)   - name matters: party type guard
        SalesmanId       INT            NULL,         -- masterdata.Parties (IsSalesman) - name matters: party type guard
        PriceListId      INT            NOT NULL,
        CurrencyId       INT            NOT NULL,     -- = price list currency (snapshot)
        RateType         TINYINT        NOT NULL CONSTRAINT DF_SalesDocuments_RateType DEFAULT (1),   -- 1 Official, 2 NonOfficial, 3 Market
        ExchangeRate     DECIMAL(18,6)  NOT NULL CONSTRAINT DF_SalesDocuments_Rate DEFAULT (1),       -- 1 base = Rate x currency
        ReferenceNo      NVARCHAR(100)  NULL,         -- client order / external reference
        Notes            NVARCHAR(1000) NULL,
        Status           TINYINT        NOT NULL CONSTRAINT DF_SalesDocuments_Status DEFAULT (1),     -- 1 Draft, 2 Posted, 3 Cancelled
        TotalItems       INT            NOT NULL CONSTRAINT DF_SalesDocuments_TotalItems DEFAULT (0),
        TotalQuantity    INT            NOT NULL CONSTRAINT DF_SalesDocuments_TotalQuantity DEFAULT (0),   -- base units
        Subtotal         DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_Subtotal DEFAULT (0),       -- before discounts, invoice currency
        TotalDiscount    DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalDiscount DEFAULT (0),
        TotalAmount      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalAmount DEFAULT (0),    -- invoice currency
        TotalAmountBase  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalAmountBase DEFAULT (0),-- base currency (= TotalAmount / ExchangeRate)
        TotalCostBase    DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SalesDocuments_TotalCostBase DEFAULT (0),  -- COGS at posting, base currency
        SourceDocumentId INT            NULL,         -- family pattern: SO -> SINV / SINV -> SRET conversions (later)
        PostedAtUtc      DATETIME2(3)   NULL,
        PostedBy         INT            NULL,
        CancelledAtUtc   DATETIME2(3)   NULL,
        CancelledBy      INT            NULL,
        CancelReason     NVARCHAR(300)  NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_SalesDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        UpdatedAtUtc     DATETIME2(3)   NULL,
        UpdatedBy        INT            NULL,
        RowVersion       ROWVERSION     NOT NULL,
        CONSTRAINT PK_SalesDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_SalesDocuments_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT CK_SalesDocuments_RateType CHECK (RateType IN (1, 2, 3)),
        CONSTRAINT CK_SalesDocuments_Rate CHECK (ExchangeRate > 0),
        CONSTRAINT CK_SalesDocuments_DueDate CHECK (DueDate IS NULL OR DueDate >= DocumentDate),
        CONSTRAINT FK_SalesDocuments_Type        FOREIGN KEY (DocumentTypeId)   REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_SalesDocuments_Branch      FOREIGN KEY (BranchId)         REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_SalesDocuments_Warehouse   FOREIGN KEY (WarehouseId)      REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_SalesDocuments_Client      FOREIGN KEY (ClientId)         REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_SalesDocuments_Salesman    FOREIGN KEY (SalesmanId)       REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_SalesDocuments_PriceList   FOREIGN KEY (PriceListId)      REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_SalesDocuments_Currency    FOREIGN KEY (CurrencyId)       REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_SalesDocuments_Source      FOREIGN KEY (SourceDocumentId) REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_SalesDocuments_CreatedBy   FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_SalesDocuments_UpdatedBy   FOREIGN KEY (UpdatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_SalesDocuments_PostedBy    FOREIGN KEY (PostedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_SalesDocuments_CancelledBy FOREIGN KEY (CancelledBy)      REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_SalesDocuments_Number ON sales.SalesDocuments (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_TypeDate   ON sales.SalesDocuments (DocumentTypeId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_TypeStatus ON sales.SalesDocuments (DocumentTypeId, Status);
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_Client     ON sales.SalesDocuments (ClientId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_SalesDocuments_Salesman   ON sales.SalesDocuments (SalesmanId) WHERE SalesmanId IS NOT NULL;
    PRINT 'Created sales.SalesDocuments';
END
GO

IF OBJECT_ID(N'sales.SalesDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocumentLines
    (
        Id              INT IDENTITY(1,1) NOT NULL,
        DocumentId      INT           NOT NULL,
        LineNumber      INT           NOT NULL,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        WarehouseId     INT           NOT NULL,
        ExpiryDate      DATE          NULL,
        Quantity        INT           NOT NULL,          -- in the chosen unit
        PackingFormula  INT           NOT NULL,          -- snapshot from the item unit at save time
        QuantityBase    AS (Quantity * PackingFormula) PERSISTED,
        UnitPrice       DECIMAL(18,4) NOT NULL,          -- per unit, invoice currency
        DiscountPercent DECIMAL(9,4)  NOT NULL CONSTRAINT DF_SalesDocumentLines_Discount DEFAULT (0),
        LineDiscount    AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * DiscountPercent / 100.0)) PERSISTED,
        LineTotal       AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * (1 - DiscountPercent / 100.0))) PERSISTED,
        PriceSource     NVARCHAR(20)  NOT NULL CONSTRAINT DF_SalesDocumentLines_PriceSource DEFAULT (N'PriceList'),   -- PriceList | Manual
        UnitCostBase    DECIMAL(18,6) NULL,              -- COGS per BASE unit (base currency), snapshot at posting
        ImportRowNumber INT           NULL,              -- Excel row the line came from (traceability)
        Notes           NVARCHAR(300) NULL,
        SourceLineId    INT           NULL,              -- family pattern (conversions) - unused for now
        CONSTRAINT PK_SalesDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_SalesDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT CK_SalesDocumentLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_SalesDocumentLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_SalesDocumentLines_Price CHECK (UnitPrice >= 0),
        CONSTRAINT CK_SalesDocumentLines_Discount CHECK (DiscountPercent BETWEEN 0 AND 100),
        CONSTRAINT CK_SalesDocumentLines_PriceSource CHECK (PriceSource IN (N'PriceList', N'Manual')),
        CONSTRAINT FK_SalesDocumentLines_Document  FOREIGN KEY (DocumentId)  REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_SalesDocumentLines_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_SalesDocumentLines_ItemUnit  FOREIGN KEY (ItemUnitId)  REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_SalesDocumentLines_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id)
    );
    CREATE NONCLUSTERED INDEX IX_SalesDocumentLines_Document ON sales.SalesDocumentLines (DocumentId);
    CREATE NONCLUSTERED INDEX IX_SalesDocumentLines_Item     ON sales.SalesDocumentLines (ItemId);
    PRINT 'Created sales.SalesDocumentLines';
END
GO

IF OBJECT_ID(N'sales.SalesDocumentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocumentFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        DocumentId   INT            NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_SalesDocumentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_SalesDocumentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_SalesDocumentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_SalesDocumentFiles_Document  FOREIGN KEY (DocumentId) REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_SalesDocumentFiles_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_SalesDocumentFiles_Document ON sales.SalesDocumentFiles (DocumentId);
    PRINT 'Created sales.SalesDocumentFiles';
END
GO

IF OBJECT_ID(N'sales.SalesDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE sales.SalesDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Imported | Posted | Cancelled | FileAdded | FileDeleted
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_SalesDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_SalesDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_SalesDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_SalesDocumentAudit_Document ON sales.SalesDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created sales.SalesDocumentAudit';
END
GO

-- Import logs: PriceListId becomes optional (stock-mode imports have no price list) and InvoiceId points to real invoices.
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'sales.InvoiceImportLogs') AND name = N'PriceListId' AND is_nullable = 0)
BEGIN
    ALTER TABLE sales.InvoiceImportLogs ALTER COLUMN PriceListId INT NULL;
    PRINT 'sales.InvoiceImportLogs.PriceListId is now nullable (stock-mode imports)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_InvoiceImportLogs_Invoice')
BEGIN
    ALTER TABLE sales.InvoiceImportLogs WITH CHECK
        ADD CONSTRAINT FK_InvoiceImportLogs_Invoice FOREIGN KEY (InvoiceId) REFERENCES sales.SalesDocuments (Id);
    PRINT 'Added FK sales.InvoiceImportLogs.InvoiceId -> sales.SalesDocuments';
END
GO

-- RE-CREATED (script 14): same signature; @PriceListId may be NULL; an @InvoiceId must exist and gets an "Imported" audit row.
CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Log
    @BranchId       INT,
    @WarehouseId    INT,
    @PriceListId    INT          = NULL,
    @FileName       NVARCHAR(255),
    @TotalRows      INT,
    @ImportedRows   INT,
    @WarningRows    INT,
    @RejectedRows   INT,
    @DraftReference NVARCHAR(50) = NULL,
    @InvoiceId      INT          = NULL,
    @ImportedBy     INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 61000, 'File name is required.', 1;
    IF @InvoiceId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @InvoiceId)
        THROW 61000, 'Invoice not found.', 1;

    INSERT INTO sales.InvoiceImportLogs (InvoiceId, DraftReference, BranchId, WarehouseId, PriceListId, FileName,
                                         TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
    VALUES (@InvoiceId, NULLIF(LTRIM(RTRIM(@DraftReference)), N''), @BranchId, @WarehouseId, @PriceListId, LTRIM(RTRIM(@FileName)),
            ISNULL(@TotalRows, 0), ISNULL(@ImportedRows, 0), ISNULL(@WarningRows, 0), ISNULL(@RejectedRows, 0), @ImportedBy);
    SET @NewId = SCOPE_IDENTITY();

    IF @InvoiceId IS NOT NULL
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Imported', N'Excel import: ' + LTRIM(RTRIM(@FileName)) + N' (' + CAST(ISNULL(@ImportedRows, 0) AS NVARCHAR(10)) + N' row(s))', @ImportedBy);
END
GO

IF TYPE_ID(N'sales.tvp_SalesDocumentLine') IS NULL
BEGIN
    CREATE TYPE sales.tvp_SalesDocumentLine AS TABLE
    (
        LineNumber      INT           NOT NULL PRIMARY KEY,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        WarehouseId     INT           NOT NULL,
        ExpiryDate      DATE          NULL,
        Quantity        INT           NOT NULL,
        UnitPrice       DECIMAL(18,4) NULL,       -- NULL = price list price; a value is kept only with @AllowPriceOverride = 1
        DiscountPercent DECIMAL(9,4)  NULL,       -- NULL = 0
        ImportRowNumber INT           NULL,
        Notes           NVARCHAR(300) NULL
    );
    PRINT 'Created type sales.tvp_SalesDocumentLine';
END
GO

/* ================================================================== 2. Search / Get / rate helper */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Search
    @DocumentTypeCode NVARCHAR(20) = N'SINV',  -- SO | SINV | SRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, reference, client code/name, notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @ClientId         INT          = NULL,
    @SalesmanId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | ClientName | Status | TotalAmount | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'ClientName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.DueDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName,
           d.SalesmanId, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListName, d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.ReferenceNo, d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Sales'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.ReferenceNo LIKE N'%' + @Search + N'%'
           OR cl.PartyCode LIKE N'%' + @Search + N'%' OR cl.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@ClientId IS NULL OR d.ClientId = @ClientId)
      AND (@SalesmanId IS NULL OR d.SalesmanId = @SalesmanId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'ClientName' THEN cl.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'ClientName' THEN cl.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: header, lines, file metadata, audit trail.
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.DueDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Phone AS ClientPhone, cl.Email AS ClientEmail, cl.Address AS ClientAddress,
           d.SalesmanId, sm.PartyCode AS SalesmanCode, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListCode, pl.PriceListName,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.ReferenceNo, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalCostBase,
           d.SourceDocumentId,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal, l.PriceSource,
           l.UnitCostBase, l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           SystemPrice = masterdata.fn_GetUnitPrice(l.ItemUnitId, d.PriceListId, d.BranchId)   -- current price list price (info)
    FROM sales.SalesDocumentLines l
    INNER JOIN sales.SalesDocuments d   ON d.Id = l.DocumentId
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.SalesDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.SalesDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

-- Rate the page shows (and pre-fills) for a price list currency: 1 row (Rate NULL when none is defined).
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ResolveRate
    @PriceListId INT,
    @RateType    TINYINT = 1,
    @AsOfDate    DATE    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    SELECT pl.Id AS PriceListId, pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(pl.CurrencyId, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = pl.CurrencyId AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE pl.Id = @PriceListId;
END
GO

/* ================================================================== 3. Validation helper (header + lines) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @DueDate            DATE,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT,
    @PriceListId        INT,
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),          -- NULL = resolve from the rates table
    @MaxDiscountPercent DECIMAL(9,4),
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @CurrencyId         INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Sales' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 64008, 'Document type not found, inactive, or not a sales document.', 1;

    IF @DocumentDate IS NULL THROW 64000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 64000, 'Document Date cannot be in the future.', 1;
    IF @DueDate IS NOT NULL AND @DueDate < @DocumentDate THROW 64000, 'Due Date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 64008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 64008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @ClientId IS NULL THROW 64000, 'Client is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1 AND IsActive = 1)
        THROW 64008, 'Client not found, inactive, or not flagged as a client.', 1;
    IF @SalesmanId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SalesmanId AND IsSalesman = 1 AND IsActive = 1)
        THROW 64008, 'Salesman not found, inactive, or not flagged as a salesman.', 1;
    IF @PriceListId IS NULL THROW 64000, 'Price List is required.', 1;

    SELECT @CurrencyId = CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 64008, 'Price list not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 64008, 'The price list currency is inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 64000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 64000, 'Exchange rate must be greater than zero.', 1;

    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;   -- base currency: always 1
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 64008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
END
GO

/* ================================================================== 4. Save (create or update a DRAFT) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,    -- NULL = create
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,    -- NULL = from the rates table at the document date
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,       -- user holds sales.invoices.priceoverride
    @MaxDiscountPercent DECIMAL(9,4)   = 100,     -- configuration Sales:MaxDiscountPercent
    @DraftReference     NVARCHAR(50)   = NULL,    -- links the Excel import logs written before the first save
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT, @Rate DECIMAL(18,6);
    EXEC sales.usp_SalesDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
         @PriceListId, @RateType, @ExchangeRate, @MaxDiscountPercent, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 64000, 'The document type cannot be changed.', 1;
    END

    -- Resolve prices: price list price unless a manual price is allowed and given.
    DECLARE @Priced TABLE
    (
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, WarehouseId INT, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    CROSS APPLY (SELECT masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) AS Price) sp;

    DECLARE @NoPrice NVARCHAR(400);
    SELECT TOP (1) @NoPrice = N'Line ' + CAST(p.LineNumber AS NVARCHAR(10)) + N': no selling price for ' + i.ItemCode + N' (' + ut.UnitTypeName
                              + N') in price list ' + pl.PriceListName + N'. Add the price or enter a manual price (requires the price override permission).'
    FROM @Priced p
    INNER JOIN inventory.Items i       ON i.Id = p.ItemId
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = @PriceListId
    WHERE p.UnitPrice IS NULL
    ORDER BY p.LineNumber;
    IF @NoPrice IS NOT NULL THROW 64011, @NoPrice, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT;

            INSERT INTO sales.SalesDocuments (DocumentTypeId, DocumentNumber, DocumentDate, DueDate, BranchId, WarehouseId, ClientId, SalesmanId,
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE sales.SalesDocuments
            SET DocumentDate = @DocumentDate, DueDate = @DueDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                ClientId = @ClientId, SalesmanId = @SalesmanId, PriceListId = @PriceListId, CurrencyId = @CurrencyId,
                RateType = @RateType, ExchangeRate = @Rate, ReferenceNo = @ReferenceNo, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                              UnitPrice, DiscountPercent, PriceSource, ImportRowNumber, Notes)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, p.WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula,
               p.UnitPrice, p.DiscountPercent,
               CASE WHEN p.SystemPrice IS NULL OR p.UnitPrice <> p.SystemPrice THEN N'Manual' ELSE N'PriceList' END,
               p.ImportRowNumber, p.Notes
        FROM @Priced p;

        -- Totals (invoice currency) + base-currency equivalent. TotalDiscount = Subtotal - TotalAmount so they always reconcile.
        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        -- Link the import logs written before the first save (client-side draft reference) and audit them once.
        IF @DraftReference IS NOT NULL
        BEGIN
            DECLARE @NewLogs TABLE (Id INT PRIMARY KEY, FileName NVARCHAR(255), ImportedRows INT);
            INSERT INTO @NewLogs (Id, FileName, ImportedRows)
            SELECT Id, FileName, ImportedRows FROM sales.InvoiceImportLogs WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;

            EXEC sales.usp_InvoiceImport_AttachInvoice @DraftReference, @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            SELECT @Id, N'Imported', N'Excel import: ' + FileName + N' (' + CAST(ImportedRows AS NVARCHAR(10)) + N' row(s))', @UserId
            FROM @NewLogs ORDER BY Id;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. Post (ledger + COGS + number) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocumentLines WHERE DocumentId = @Id)
            THROW 64009, 'The document has no lines. Import at least one item before posting.', 1;

        -- Masters must still be valid at posting time.
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

        -- Invoices (stock out) cannot exceed the stock on hand per item + warehouse.
        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT;

        -- COGS snapshot per line (average cost per base unit at posting); returns keep a given cost when present.
        UPDATE l SET UnitCostBase = ISNULL(CASE WHEN @Direction = 1 THEN l.UnitCostBase END, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
        FROM sales.SalesDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        UPDATE d
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            TotalCostBase = ISNULL(x.Cost, 0), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT SUM(CONVERT(DECIMAL(18,2), QuantityBase * ISNULL(UnitCostBase, 0))) AS Cost FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM sales.SalesDocumentLines WHERE DocumentId = @Id);
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Cancel (reversal) / Delete draft */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Cancelling a document that ADDED stock (sales return) removes it again: it must still be there.
        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 64006, 'Document not found.', 1;
    IF @Status <> 1 THROW 64005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE sales.InvoiceImportLogs SET InvoiceId = NULL WHERE InvoiceId = @Id;   -- keep the import history
        DELETE FROM sales.SalesDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Attachments */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @DocumentId) THROW 64006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 64000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 64000, 'The file is empty.', 1;

    INSERT INTO sales.SalesDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM sales.SalesDocumentFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM sales.SalesDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 64006, 'File not found.', 1;
    DELETE FROM sales.SalesDocumentFiles WHERE Id = @Id;
    INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 8. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'sales.invoices.view',   N'View Sales Invoices',   N'Sales', N'See sales invoices.',                                 620),
        (N'sales.invoices.create', N'Create Sales Invoices', N'Sales', N'Create and edit draft sales invoices.',               630),
        (N'sales.invoices.post',   N'Post Sales Invoices',   N'Sales', N'Post sales invoices (removes stock, assigns number).', 640),
        (N'sales.invoices.cancel', N'Cancel Sales Invoices', N'Sales', N'Cancel posted sales invoices (stock reversal).',      650),
        (N'sales.invoices.delete', N'Delete Sales Invoices', N'Sales', N'Delete draft sales invoices.',                        660)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code IN (N'sales.invoices.view', N'sales.invoices.create', N'sales.invoices.post', N'sales.invoices.cancel', N'sales.invoices.delete')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'sales.invoices.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 9. Demo client (only when no client exists) + report */

IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE IsClient = 1)
BEGIN
    DECLARE @Pl INT = (SELECT TOP (1) Id FROM masterdata.PriceLists WHERE IsActive = 1 ORDER BY Id);
    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, DefaultPriceListId, IsActive)
    VALUES (N'CLI-0001', N'Walk-in Customer', 0, 1, 0, 0, @Pl, 1);
    PRINT 'Seeded client CLI-0001 Walk-in Customer';
END
GO

-- ===== 18: Import stock check =====

/* =====================================================================================
   Inventory_Shipment - 18: Excel import validation checks STOCK (for "validate -> post to stock")

   RE-CREATES sales.usp_InvoiceImport_Validate (scripts 14/15) with one new parameter and two new
   output columns - everything else is unchanged:
     @CheckStock BIT = 0   1 = rows that would take more than the stock on hand become Errors.
                            The check is CUMULATIVE in file order per item + warehouse (row 5 for the
                            same item/warehouse as row 2 sees what row 2 already takes), in BASE units.
     OnHandBase            stock on hand for the row's item + warehouse (base units) - shown in the preview
     RequiredBase          base units required by this row plus the rows above it for the same item + warehouse

   Message: "Insufficient stock for TVS-AP160 in WH-001: available 3, required 5 (rows 2, 5)."
   Used by the "Import Sales from Excel" page: validate (with stock) -> preview -> post as a Sales Invoice
   (script 17: usp_SalesDocument_Save + usp_SalesDocument_Post) -> stock movements.

   Requires 15 (ledger) and 17 (sales documents). Idempotent.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.fn_StockOnHand', N'FN') IS NULL OR OBJECT_ID(N'sales.usp_SalesDocument_Post', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 15 and 17 before this script.', 16, 1);
    RETURN;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = stock document: no pricing, Unit Price column = unit cost (optional)
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY,
    @CheckStock          BIT           = 0      -- 1 = quantities are checked against the stock on hand (cumulative per item + warehouse)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the selected branch.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    SET @CheckStock = ISNULL(@CheckStock, 0);

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE WHEN @PriceListId IS NULL THEN CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END       -- stock docs: base unit first
                          ELSE CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END END, iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    stocked AS
    (
        -- Base units required by this row (0 when the row cannot be quantified) and the running total per item + warehouse.
        SELECT x.*,
               QtyBase      = CASE WHEN x.ItemUnitId IS NOT NULL AND x.Quantity IS NOT NULL AND x.Quantity > 0 AND x.Quantity = FLOOR(x.Quantity)
                                   THEN CAST(x.Quantity AS INT) * x.PackingFormula ELSE 0 END,
               OnHandBase   = CASE WHEN x.ItemId IS NOT NULL AND x.WarehouseId IS NOT NULL THEN inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) END
        FROM resolved x
    ),
    running AS
    (
        SELECT s.*,
               RequiredBase = SUM(s.QtyBase) OVER (PARTITION BY s.ItemId, s.WarehouseId ORDER BY s.RowNumber ROWS UNBOUNDED PRECEDING),
               EarlierRows  = STUFF((SELECT N', ' + CAST(s2.RowNumber AS NVARCHAR(10))
                                     FROM stocked s2
                                     WHERE s2.ItemId = s.ItemId AND s2.WarehouseId = s.WarehouseId AND s2.QtyBase > 0 AND s2.RowNumber < s.RowNumber
                                     ORDER BY s2.RowNumber FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'')
        FROM stocked s
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Err8 = CASE WHEN @CheckStock = 1 AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL AND x.WarehouseBranchId = @BranchId AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Insufficient stock for ' + x.ItemCode + N' in ' + x.WarehouseCode + N': available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', required ' + CAST(x.RequiredBase AS NVARCHAR(20))
                                     + CASE WHEN x.EarlierRows IS NULL THEN N'' ELSE N' (with rows ' + x.EarlierRows + N')' END + N'.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @PriceListId IS NOT NULL AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.' END
        FROM running x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7, j.Err8) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''), ISNULL(j.Err8 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes,
           j.OnHandBase, j.RequiredBase
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

-- ===== 19: Document engine =====

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 19: Document engine upgrade (all families)

   1. inventory.DocumentTypes  + DefaultPricing (Cost | PriceList | None), PriceEditable, NumberPerBranch
                               + usp_DocumentType_List (new columns), usp_DocumentType_Update (configuration page)
   2. Numbering PER BRANCH     inventory.DocumentSequences (type x branch) and usp_DocumentType_NextNumber
                               re-created: "INV-KLW-000001" = prefix + branch code + '-' + sequence.
                               (types with NumberPerBranch = 0 keep the old company-wide "IN-000001").
                               Branch codes used in numbers are cut to 8 characters - keep them short.
   3. inventory.Items          + AverageCost (MOVING average, kept on the item), LastCost, LastSupplierId,
                               LastPurchaseAtUtc, DefaultSupplierId, LeadTimeDays
                               + tvp_ItemReceipt / usp_Item_ApplyReceipts (the moving-average rule, called by every
                                 posting that ADDS stock, before the movements are written):
                                   new avg = (on-hand x old avg + received qty x cost) / (on-hand + received qty)
                               + usp_Item_SetPurchasing (default supplier / lead time)
                               + fn_AverageCost now returns Items.AverageCost; usp_Item_Search / usp_Item_Get re-created
                               (one-time backfill of AverageCost / LastCost from the ledger for existing items).
   4. ONE DOCUMENT = ONE WAREHOUSE: lines always take the header warehouse (Save procs force it; the pages hide
                               the per-line warehouse column; the Excel import creates one document per warehouse).
   5. Re-created with 2 + 3 + 4: inventory.usp_StockDocument_ValidateInput / _Save / _Post,
                               sales.usp_SalesDocument_ValidateInput / _Save / _Post.
      Cancelling a receipt does NOT recompute the moving average (standard practice; the reversal keeps its cost).

   Requires 15 and 17. Idempotent.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.DocumentTypes', N'U') IS NULL OR OBJECT_ID(N'sales.SalesDocuments', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 15 and 17 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. DocumentTypes configuration */

IF COL_LENGTH(N'inventory.DocumentTypes', N'DefaultPricing') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        DefaultPricing  NVARCHAR(10) NOT NULL CONSTRAINT DF_DocumentTypes_DefaultPricing DEFAULT (N'Cost'),
        PriceEditable   BIT          NOT NULL CONSTRAINT DF_DocumentTypes_PriceEditable DEFAULT (1),
        NumberPerBranch BIT          NOT NULL CONSTRAINT DF_DocumentTypes_NumberPerBranch DEFAULT (1),
        CONSTRAINT CK_DocumentTypes_DefaultPricing CHECK (DefaultPricing IN (N'Cost', N'PriceList', N'None'));
    PRINT 'DocumentTypes: added DefaultPricing, PriceEditable, NumberPerBranch';
END
GO

-- Behaviour per type (the configuration page can change these later).
UPDATE dt SET DefaultPricing = s.Pricing, PriceEditable = s.Editable, NumberPerBranch = 1
FROM inventory.DocumentTypes dt
INNER JOIN (VALUES
    (N'INV_IN',  N'Cost',      1),   -- cost entered by the user
    (N'INV_OUT', N'Cost',      0),   -- moving average applied automatically, read-only
    (N'PO',      N'Cost',      1),   -- supplier price, default = item last cost
    (N'PINV',    N'Cost',      1),
    (N'PRET',    N'Cost',      1),
    (N'SO',      N'PriceList', 1),
    (N'SINV',    N'PriceList', 1),   -- editable only with sales.invoices.priceoverride
    (N'SRET',    N'PriceList', 1)
) AS s (Code, Pricing, Editable) ON s.Code = dt.Code;
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_Update
    @Id              INT,
    @Name            NVARCHAR(100),
    @NumberPrefix    NVARCHAR(10),
    @NumberLength    TINYINT,
    @NumberOnPost    BIT,
    @RequiresReason  BIT,
    @DefaultPricing  NVARCHAR(10),
    @PriceEditable   BIT,
    @NumberPerBranch BIT,
    @IsActive        BIT,
    @RowVersion      BINARY(8) = NULL,
    @UserId          INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @NumberPrefix = NULLIF(LTRIM(RTRIM(@NumberPrefix)), N'');
    IF @Name IS NULL THROW 62000, 'Name is required.', 1;
    IF @NumberPrefix IS NULL THROW 62000, 'Number prefix is required.', 1;
    IF @NumberLength IS NULL OR @NumberLength NOT BETWEEN 3 AND 10 THROW 62000, 'Number length must be between 3 and 10.', 1;
    IF @DefaultPricing NOT IN (N'Cost', N'PriceList', N'None') THROW 62000, 'Default pricing must be Cost, PriceList or None.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id) THROW 62006, 'Document type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 62004, 'This document type was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.DocumentTypes
    SET Name = @Name, NumberPrefix = @NumberPrefix, NumberLength = @NumberLength, NumberOnPost = ISNULL(@NumberOnPost, 0),
        RequiresReason = ISNULL(@RequiresReason, 0), DefaultPricing = @DefaultPricing, PriceEditable = ISNULL(@PriceEditable, 1),
        NumberPerBranch = ISNULL(@NumberPerBranch, 1), IsActive = ISNULL(@IsActive, 1),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

/* ================================================================== 2. Numbering per branch */

IF OBJECT_ID(N'inventory.DocumentSequences', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.DocumentSequences
    (
        DocumentTypeId INT NOT NULL,
        BranchId       INT NOT NULL,
        NextNumber     INT NOT NULL CONSTRAINT DF_DocumentSequences_Next DEFAULT (1),
        CONSTRAINT PK_DocumentSequences PRIMARY KEY CLUSTERED (DocumentTypeId, BranchId),
        CONSTRAINT FK_DocumentSequences_Type   FOREIGN KEY (DocumentTypeId) REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_DocumentSequences_Branch FOREIGN KEY (BranchId)       REFERENCES masterdata.Branches (Id)
    );
    PRINT 'Created inventory.DocumentSequences';
END
GO

-- Atomic next number. Per-branch types: prefix + branch code + '-' + zero-padded sequence (INV-KLW-000001).
-- The third parameter is optional so older callers keep working (they get the company-wide format).
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT,
    @BranchId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId INT, @Prefix NVARCHAR(10), @Len TINYINT, @PerBranch BIT;
    SELECT @TypeId = Id, @Prefix = NumberPrefix, @Len = NumberLength, @PerBranch = NumberPerBranch
    FROM inventory.DocumentTypes WHERE Code = @Code AND IsActive = 1;
    IF @TypeId IS NULL THROW 62008, 'Document type not found or inactive.', 1;

    DECLARE @Taken TABLE (Number INT);

    IF @PerBranch = 1 AND @BranchId IS NOT NULL
    BEGIN
        DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
        IF @BranchCode IS NULL THROW 62008, 'Branch not found.', 1;

        MERGE inventory.DocumentSequences WITH (HOLDLOCK) AS t
        USING (SELECT @TypeId AS DocumentTypeId, @BranchId AS BranchId) AS s
            ON t.DocumentTypeId = s.DocumentTypeId AND t.BranchId = s.BranchId
        WHEN MATCHED THEN UPDATE SET NextNumber = t.NextNumber + 1
        WHEN NOT MATCHED THEN INSERT (DocumentTypeId, BranchId, NextNumber) VALUES (s.DocumentTypeId, s.BranchId, 2)
        OUTPUT ISNULL(deleted.NextNumber, 1) INTO @Taken (Number);

        SELECT @DocumentNumber = @Prefix + UPPER(LEFT(@BranchCode, 8)) + N'-' + RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len)
        FROM @Taken;
    END
    ELSE
    BEGIN
        UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
        SET NextNumber = NextNumber + 1
        OUTPUT deleted.NextNumber INTO @Taken (Number)
        WHERE Id = @TypeId;

        SELECT @DocumentNumber = @Prefix + RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len) FROM @Taken;
    END
END
GO

/* ================================================================== 3. Items: moving average, last cost, purchasing defaults */

IF COL_LENGTH(N'inventory.Items', N'AverageCost') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD
        AverageCost       DECIMAL(18,6) NOT NULL CONSTRAINT DF_Items_AverageCost DEFAULT (0),   -- per BASE unit, base currency
        LastCost          DECIMAL(18,6) NULL,                                                   -- per BASE unit, base currency
        LastSupplierId    INT           NULL,
        LastPurchaseAtUtc DATETIME2(3)  NULL,
        DefaultSupplierId INT           NULL,
        LeadTimeDays      INT           NULL,
        CONSTRAINT CK_Items_LeadTime CHECK (LeadTimeDays IS NULL OR LeadTimeDays >= 0),
        CONSTRAINT FK_Items_LastSupplier    FOREIGN KEY (LastSupplierId)    REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_Items_DefaultSupplier FOREIGN KEY (DefaultSupplierId) REFERENCES masterdata.Parties (Id);
    PRINT 'Items: added AverageCost, LastCost, LastSupplierId, LastPurchaseAtUtc, DefaultSupplierId, LeadTimeDays';
END
GO

-- One-time backfill from the ledger (items that already have receipts but no stored average).
UPDATE i
SET AverageCost = ISNULL(x.Avg, 0),
    LastCost = x.Last
FROM inventory.Items i
CROSS APPLY
(
    SELECT Avg  = (SELECT CASE WHEN SUM(m.QuantityBase) > 0 THEN SUM(m.QuantityBase * ISNULL(m.UnitCostBase, 0)) / SUM(m.QuantityBase) END
                   FROM inventory.StockMovements m WHERE m.ItemId = i.Id AND m.QuantityBase > 0 AND m.IsReversal = 0),
           Last = (SELECT TOP (1) m.UnitCostBase FROM inventory.StockMovements m
                   WHERE m.ItemId = i.Id AND m.QuantityBase > 0 AND m.IsReversal = 0 ORDER BY m.MovementDate DESC, m.Id DESC)
) x
WHERE i.AverageCost = 0 AND i.LastCost IS NULL AND x.Avg IS NOT NULL AND x.Avg > 0;
GO

CREATE OR ALTER FUNCTION inventory.fn_AverageCost (@ItemId INT)
RETURNS DECIMAL(18,6)
AS
BEGIN
    RETURN (SELECT AverageCost FROM inventory.Items WHERE Id = @ItemId);
END
GO

IF TYPE_ID(N'inventory.tvp_ItemReceipt') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ItemReceipt AS TABLE
    (
        ItemId       INT           NOT NULL,
        QuantityBase INT           NOT NULL,   -- received, base units (> 0)
        UnitCostBase DECIMAL(18,6) NOT NULL    -- per base unit, base currency
    );
    PRINT 'Created type inventory.tvp_ItemReceipt';
END
GO

-- Moving average: CALL BEFORE the receipt movements are inserted (on-hand must be the quantity before the receipt).
CREATE OR ALTER PROCEDURE inventory.usp_Item_ApplyReceipts
    @Receipts   inventory.tvp_ItemReceipt READONLY,
    @SupplierId INT = NULL,      -- purchases: becomes the item's last supplier
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT ItemId, Qty = SUM(QuantityBase), Cost = SUM(CAST(QuantityBase AS DECIMAL(18,6)) * UnitCostBase)
        FROM @Receipts WHERE QuantityBase > 0 GROUP BY ItemId
    )
    UPDATE i
    SET AverageCost = CASE WHEN oh.Q + a.Qty > 0 THEN (oh.Q * i.AverageCost + a.Cost) / (oh.Q + a.Qty) ELSE i.AverageCost END,
        LastCost = a.Cost / a.Qty,
        LastSupplierId = COALESCE(@SupplierId, i.LastSupplierId),
        LastPurchaseAtUtc = CASE WHEN @SupplierId IS NOT NULL THEN SYSUTCDATETIME() ELSE i.LastPurchaseAtUtc END
    FROM inventory.Items i
    INNER JOIN agg a ON a.ItemId = i.Id
    CROSS APPLY (SELECT Q = CAST(CASE WHEN inventory.fn_StockOnHand(i.Id, NULL) > 0 THEN inventory.fn_StockOnHand(i.Id, NULL) ELSE 0 END AS DECIMAL(18,6))) oh;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT = NULL,
    @LeadTimeDays      INT = NULL,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Search
    @Search             NVARCHAR(200) = NULL,
    @ItemFamilyId       INT           = NULL,
    @BrandId            INT           = NULL,
    @DefaultWarehouseId INT           = NULL,
    @IsActive           BIT           = NULL,
    @IsBivac            BIT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'ItemCode',
    @SortDirection      NVARCHAR(4)   = N'ASC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BrandName', N'FamilyName', N'WarehouseName', N'IsActive', N'CreatedAtUtc', N'OnHand')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           bu.SkuCode AS BaseUnitSku, ut.UnitTypeName AS BaseUnitName,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)), LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           i.DefaultSupplierId, ds.PartyName AS DefaultSupplierName,
           i.CreatedAtUtc, i.CreatedBy, i.UpdatedAtUtc, i.UpdatedBy, i.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b        ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN inventory.ItemUnits bu     ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes ut    ON ut.Id = bu.UnitTypeId
    LEFT  JOIN masterdata.Parties ds      ON ds.Id = i.DefaultSupplierId
    WHERE (@Search IS NULL
           OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u
                      WHERE u.ItemId = i.Id AND (u.SkuCode LIKE N'%' + @Search + N'%' OR u.Barcode LIKE N'%' + @Search + N'%')))
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@DefaultWarehouseId IS NULL OR i.DefaultWarehouseId = @DefaultWarehouseId)
      AND (@IsActive IS NULL OR i.IsActive = @IsActive)
      AND (@IsBivac IS NULL OR i.IsBivac = @IsBivac)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END DESC,
        i.ItemCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                               WHERE m.ItemId = i.Id AND m.DocumentFamily = N'Purchase' AND m.QuantityBase > 0 AND m.IsReversal = 0
                               ORDER BY m.MovementDate DESC, m.Id DESC),
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 4. Stock documents (Inventory In / Out) re-created */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT;
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 62008, 'The warehouse must be an active warehouse of the selected branch.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks (the warehouse is the header's - one document = one warehouse).
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Save
    @Id               INT            = NULL,   -- NULL = create
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT,
    @ReasonId         INT            = NULL,
    @ReferenceNo      NVARCHAR(100)  = NULL,
    @Notes            NVARCHAR(1000) = NULL,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @RowVersion       BINARY(8)      = NULL,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT;
    EXEC inventory.usp_StockDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 62000, 'The document type cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO inventory.StockDocuments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, WarehouseId, ReasonId,
                                                  ReferenceNo, CurrencyId, ExchangeRate, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @ReferenceNo, @CurrencyId, 1, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.StockDocuments
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, ReasonId = @ReasonId,
                ReferenceNo = @ReferenceNo, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines: warehouse = header warehouse; Out documents take the item's moving average cost (per unit).
        INSERT INTO inventory.StockDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, UnitCost, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, @WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               CASE WHEN @Direction = -1 THEN ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * iu.PackingFormula ELSE ISNULL(l.UnitCost, 0) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId;

        UPDATE d SET TotalItems = x.Items, TotalQuantity = x.Qty, TotalCost = x.Cost
        FROM inventory.StockDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty, ISNULL(SUM(LineTotal), 0) AS Cost
                     FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        IF @Direction = -1
        BEGIN
            -- Refresh the cost at posting time (moving average may have changed since the draft was saved).
            UPDATE l SET UnitCost = ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * l.PackingFormula
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

            UPDATE d SET TotalCost = x.Cost
            FROM inventory.StockDocuments d
            CROSS APPLY (SELECT ISNULL(SUM(LineTotal), 0) AS Cost FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- Receipts update the moving average BEFORE the movements exist.
        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase)
            SELECT l.ItemId, l.QuantityBase, CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula ELSE l.UnitCost END
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId;
        END

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. Sales documents re-created (branch numbering, header warehouse, receipts) */

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @DueDate            DATE,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT,
    @PriceListId        INT,
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),
    @MaxDiscountPercent DECIMAL(9,4),
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @CurrencyId         INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Sales' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 64008, 'Document type not found, inactive, or not a sales document.', 1;

    IF @DocumentDate IS NULL THROW 64000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 64000, 'Document Date cannot be in the future.', 1;
    IF @DueDate IS NOT NULL AND @DueDate < @DocumentDate THROW 64000, 'Due Date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 64008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 64008, 'The warehouse must be an active warehouse of the selected branch.', 1;
    IF @ClientId IS NULL THROW 64000, 'Client is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1 AND IsActive = 1)
        THROW 64008, 'Client not found, inactive, or not flagged as a client.', 1;
    IF @SalesmanId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SalesmanId AND IsSalesman = 1 AND IsActive = 1)
        THROW 64008, 'Salesman not found, inactive, or not flagged as a salesman.', 1;
    IF @PriceListId IS NULL THROW 64000, 'Price List is required.', 1;

    SELECT @CurrencyId = CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 64008, 'Price list not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 64008, 'The price list currency is inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 64000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 64000, 'Exchange rate must be greater than zero.', 1;

    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 64008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @DraftReference     NVARCHAR(50)   = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT, @Rate DECIMAL(18,6);
    EXEC sales.usp_SalesDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
         @PriceListId, @RateType, @ExchangeRate, @MaxDiscountPercent, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 64000, 'The document type cannot be changed.', 1;
    END

    DECLARE @Priced TABLE
    (
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    CROSS APPLY (SELECT masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) AS Price) sp;

    DECLARE @NoPrice NVARCHAR(400);
    SELECT TOP (1) @NoPrice = N'Line ' + CAST(p.LineNumber AS NVARCHAR(10)) + N': no selling price for ' + i.ItemCode + N' (' + ut.UnitTypeName
                              + N') in price list ' + pl.PriceListName + N'. Add the price or enter a manual price (requires the price override permission).'
    FROM @Priced p
    INNER JOIN inventory.Items i       ON i.Id = p.ItemId
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = @PriceListId
    WHERE p.UnitPrice IS NULL
    ORDER BY p.LineNumber;
    IF @NoPrice IS NOT NULL THROW 64011, @NoPrice, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO sales.SalesDocuments (DocumentTypeId, DocumentNumber, DocumentDate, DueDate, BranchId, WarehouseId, ClientId, SalesmanId,
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE sales.SalesDocuments
            SET DocumentDate = @DocumentDate, DueDate = @DueDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                ClientId = @ClientId, SalesmanId = @SalesmanId, PriceListId = @PriceListId, CurrencyId = @CurrencyId,
                RateType = @RateType, ExchangeRate = @Rate, ReferenceNo = @ReferenceNo, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                              UnitPrice, DiscountPercent, PriceSource, ImportRowNumber, Notes)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, @WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula,
               p.UnitPrice, p.DiscountPercent,
               CASE WHEN p.SystemPrice IS NULL OR p.UnitPrice <> p.SystemPrice THEN N'Manual' ELSE N'PriceList' END,
               p.ImportRowNumber, p.Notes
        FROM @Priced p;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        IF @DraftReference IS NOT NULL
        BEGIN
            DECLARE @NewLogs TABLE (Id INT PRIMARY KEY, FileName NVARCHAR(255), ImportedRows INT);
            INSERT INTO @NewLogs (Id, FileName, ImportedRows)
            SELECT Id, FileName, ImportedRows FROM sales.InvoiceImportLogs WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;

            EXEC sales.usp_InvoiceImport_AttachInvoice @DraftReference, @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            SELECT @Id, N'Imported', N'Excel import: ' + FileName + N' (' + CAST(ImportedRows AS NVARCHAR(10)) + N' row(s))', @UserId
            FROM @NewLogs ORDER BY Id;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocumentLines WHERE DocumentId = @Id)
            THROW 64009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- COGS snapshot per line: invoices take the moving average; returns keep their given cost (falls back to the average).
        UPDATE l SET UnitCostBase = ISNULL(CASE WHEN @Direction = 1 THEN l.UnitCostBase END, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
        FROM sales.SalesDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0) FROM sales.SalesDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        UPDATE d
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            TotalCostBase = ISNULL(x.Cost, 0), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT SUM(CONVERT(DECIMAL(18,2), QuantityBase * ISNULL(UnitCostBase, 0))) AS Cost FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM sales.SalesDocumentLines WHERE DocumentId = @Id);
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Permissions + report */

MERGE security.Permissions AS target
USING (VALUES (N'inventory.documenttypes.manage', N'Manage document types', N'Configuration', N'Change numbering, pricing and behaviour of document types.', 900))
      AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN INSERT (Code, Name, Module, Description, SortOrder) VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- ===== 20: Import common template =====

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 20: ONE Excel import template for every document type

   Template (header row; order free):
     Document Type | Item Code / Barcode | Unit | Warehouse | Quantity | Unit Price | Discount % | Expiry Date | Notes
   - Document Type = a code of inventory.DocumentTypes (INV_IN, INV_OUT, PO, PINV, PRET, SO, SINV, SRET) or its name.
     Blank = the document type of the page doing the import. A different type = row Error
     ("This row is for Purchase Invoice (PINV), not for Inventory In.").
   - Warehouse = the warehouse of the line; ONE DOCUMENT = ONE WAREHOUSE, so the page creates one document per
     warehouse found in the file (blank = the header warehouse).
   - Unit Price = selling price for Sales types (price list rules), COST for Inventory In / Purchase types,
     ignored for Inventory Out (moving average).
   - Unit blank = the item's unit preferred by the family: Sales -> sales unit, Purchase -> purchase unit,
     Inventory -> base unit (barcode rows fix the unit).

   Changes:
     sales.tvp_InvoiceImportRow      re-created with DocumentTypeCode NVARCHAR(50) as the LAST column
     sales.usp_InvoiceImport_Validate re-created: + @DocumentTypeCode (page type), unit preference by family,
                                     row type check, output columns RowDocumentTypeCode / OnHandBase / RequiredBase
     (name and other parameters unchanged - the API keeps calling the same procedure)

   Requires 18 and 19. Idempotent (the type is dropped and re-created only when the column is missing).
   ===================================================================================== */

IF OBJECT_ID(N'inventory.DocumentSequences', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 18 and 19 before this script.', 16, 1);
    RETURN;
END
GO

-- Re-create the table type with the new column (a type cannot be altered).
IF TYPE_ID(N'sales.tvp_InvoiceImportRow') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns c INNER JOIN sys.table_types tt ON tt.type_table_object_id = c.object_id
                   WHERE tt.name = N'tvp_InvoiceImportRow' AND SCHEMA_NAME(tt.schema_id) = N'sales' AND c.name = N'DocumentTypeCode')
BEGIN
    IF OBJECT_ID(N'sales.usp_InvoiceImport_Validate', N'P') IS NOT NULL DROP PROCEDURE sales.usp_InvoiceImport_Validate;
    DROP TYPE sales.tvp_InvoiceImportRow;
    PRINT 'Dropped sales.tvp_InvoiceImportRow (re-created below with DocumentTypeCode)';
END
GO

IF TYPE_ID(N'sales.tvp_InvoiceImportRow') IS NULL
BEGIN
    CREATE TYPE sales.tvp_InvoiceImportRow AS TABLE
    (
        RowNumber        INT           NOT NULL PRIMARY KEY,
        ItemRef          NVARCHAR(100) NULL,     -- item code or barcode
        UnitName         NVARCHAR(50)  NULL,     -- unit type name or SKU; blank = family's preferred unit
        WarehouseRef     NVARCHAR(150) NULL,     -- code or name; blank = header warehouse
        Quantity         DECIMAL(18,4) NULL,
        RawQuantity      NVARCHAR(50)  NULL,
        UnitPrice        DECIMAL(18,4) NULL,     -- price (sales) or cost (inventory in / purchase)
        DiscountPercent  DECIMAL(9,4)  NULL,
        ExpiryDate       DATE          NULL,
        RawExpiryDate    NVARCHAR(50)  NULL,
        Notes            NVARCHAR(300) NULL,
        DocumentTypeCode NVARCHAR(50)  NULL      -- NEW: the "Document Type" cell (code or name), blank = page type
    );
    PRINT 'Created type sales.tvp_InvoiceImportRow (with DocumentTypeCode)';
END
GO

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = cost mode (inventory / purchase): Unit Price column = cost, no price list checks
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY,
    @CheckStock          BIT           = 0,     -- 1 = cumulative stock check per item + warehouse (outgoing documents)
    @DocumentTypeCode    NVARCHAR(20)  = NULL   -- the page's document type; rows for another type become Errors
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the selected branch.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    SET @CheckStock = ISNULL(@CheckStock, 0);
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');

    DECLARE @PageTypeName NVARCHAR(100), @Family NVARCHAR(20);
    IF @DocumentTypeCode IS NOT NULL
    BEGIN
        SELECT @PageTypeName = Name, @Family = Family FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode;
        IF @PageTypeName IS NULL THROW 61008, 'Document type not found.', 1;
    END
    -- Unit preference: 1 = sales unit first, 2 = purchase unit first, 0 = base unit first.
    DECLARE @UnitPref TINYINT = CASE WHEN @Family = N'Sales' OR (@Family IS NULL AND @PriceListId IS NOT NULL) THEN 1
                                     WHEN @Family = N'Purchase' THEN 2 ELSE 0 END;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               RowTypeRef   = NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N''),
               rt.RowTypeCode, rt.RowTypeName,
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) dt.Code AS RowTypeCode, dt.Name AS RowTypeName
            FROM inventory.DocumentTypes dt
            WHERE NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N'') IS NOT NULL
              AND (dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) OR dt.Name = LTRIM(RTRIM(r.DocumentTypeCode)))
            ORDER BY CASE WHEN dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) THEN 0 ELSE 1 END
        ) rt
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE @UnitPref WHEN 1 THEN CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END
                                    WHEN 2 THEN CASE WHEN iu.IsPurchaseUnit = 1 THEN 0 ELSE 1 END
                                    ELSE CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END END,
                     iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    stocked AS
    (
        SELECT x.*,
               QtyBase    = CASE WHEN x.ItemUnitId IS NOT NULL AND x.Quantity IS NOT NULL AND x.Quantity > 0 AND x.Quantity = FLOOR(x.Quantity)
                                 THEN CAST(x.Quantity AS INT) * x.PackingFormula ELSE 0 END,
               OnHandBase = CASE WHEN x.ItemId IS NOT NULL AND x.WarehouseId IS NOT NULL THEN inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) END
        FROM resolved x
    ),
    running AS
    (
        SELECT s.*,
               RequiredBase = SUM(s.QtyBase) OVER (PARTITION BY s.ItemId, s.WarehouseId ORDER BY s.RowNumber ROWS UNBOUNDED PRECEDING),
               EarlierRows  = STUFF((SELECT N', ' + CAST(s2.RowNumber AS NVARCHAR(10))
                                     FROM stocked s2
                                     WHERE s2.ItemId = s.ItemId AND s2.WarehouseId = s.WarehouseId AND s2.QtyBase > 0 AND s2.RowNumber < s.RowNumber
                                     ORDER BY s2.RowNumber FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'')
        FROM stocked s
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err0 = CASE WHEN x.RowTypeRef IS NOT NULL AND x.RowTypeCode IS NULL THEN N'Document Type ''' + x.RowTypeRef + N''' does not exist.'
                           WHEN x.RowTypeCode IS NOT NULL AND @DocumentTypeCode IS NOT NULL AND x.RowTypeCode <> @DocumentTypeCode
                                THEN N'This row is for ' + x.RowTypeName + N' (' + x.RowTypeCode + N'), not for ' + @PageTypeName + N'.' END,
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Err8 = CASE WHEN @CheckStock = 1 AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL AND x.WarehouseBranchId = @BranchId AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Insufficient stock for ' + x.ItemCode + N' in ' + x.WarehouseCode + N': available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', required ' + CAST(x.RequiredBase AS NVARCHAR(20))
                                     + CASE WHEN x.EarlierRows IS NULL THEN N'' ELSE N' (with rows ' + x.EarlierRows + N')' END + N'.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @UnitPref = 1 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.'
                            WHEN @UnitPref = 2 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsPurchaseUnit = 1)
                                THEN N'No purchase unit is flagged for this item - the base unit was used.' END
        FROM running x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err0, j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7, j.Err8) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err0 + N' ', N''), ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''), ISNULL(j.Err8 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
           RowDocumentTypeCode = ISNULL(j.RowTypeCode, @DocumentTypeCode),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes,
           j.OnHandBase, j.RequiredBase
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

-- ===== 21: Purchase documents =====

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 21: PURCHASE document family + Shortages report

   Family Purchase (schema purchase), one header + one lines table, discriminated by inventory.DocumentTypes:
     PO   Purchase Order   - no stock effect. Draft -> Posted (= confirmed / open) -> Closed (fully received or
                             closed manually) | Cancelled (only while nothing was received against it).
     PINV Purchase Invoice - stock +, cost. Draft -> Posted (ledger, moving average, item last cost/supplier,
                             PO received quantities) -> Cancelled (reversal; PO re-opened).
     PRET Purchase Return  - stock -. Created from a posted PINV (or from scratch). Draft -> Posted (needs stock,
                             cost = the invoice cost) -> Cancelled (reversal).
   Money: the supplier CURRENCY (default = supplier's DefaultCurrencyId, else base) with RateType + ExchangeRate
          (1 base = Rate x currency; auto from masterdata.fn_GetRate, editable). Lines are priced in the document
          currency; the ledger cost per base unit in USD = UnitPrice x (1 - Disc%) / PackingFormula / Rate.
          A blank line price on PO/PINV = the item's last cost converted to the document currency.
   Conversions: usp_PurchaseDocument_CreateFromSource  PO -> PINV (remaining quantities), PINV -> PRET (invoiced -
          returned); SourceDocumentId / SourceLineId keep the link; ReceivedQuantityBase (PO lines) and
          ReturnedQuantityBase (PINV lines) track what was consumed.
   One document = one warehouse (lines take the header warehouse).

   Objects: purchase.PurchaseDocuments / PurchaseDocumentLines / PurchaseDocumentFiles / PurchaseDocumentAudit,
            purchase.tvp_PurchaseDocumentLine, usp_PurchaseDocument_Search / _Get (5 result sets: header, lines,
            files, audit, linked documents) / _ValidateInput / _Save / _Post / _Cancel / _Close / _Delete /
            _CreateFromSource, usp_PurchaseDocumentFile_Add / _Get / _Delete,
            masterdata.usp_ExchangeRate_Resolve (rate for a currency), inventory.usp_Shortage_Report.

   Shortages (general formula until the customer's formulas arrive), per item + warehouse:
     Available = OnHand + Incoming (open PO remaining, base units, same warehouse)
     Short when Available < MinQuantity;  ShortageBase = Min - Available
     SuggestedBase = ISNULL(Max, Min) - Available, rounded UP to the purchase unit (SuggestedQty in that unit)
     AvgDailySales = net Sales-family outflow of the last @DaysForAverage days / days; DaysOfCover = OnHand / AvgDailySales
     Supplier = item DefaultSupplierId, else LastSupplierId.  Evaluated at the item's default warehouse and at every
     warehouse where the item has movements (filters: branch, warehouse, family, brand, supplier, search).

   Error numbers 65xxx: 65000 validation ("Line N: ...")  65004 concurrency  65005 not a draft  65006 not found
     65007 insufficient stock  65008 master data / rate  65009 no lines  65010 invalid status  65011 source document
     problem (not posted, other supplier, quantity above remaining, already referenced)
   Permissions (module Purchase): purchase.orders.* 1000-1040, purchase.invoices.* 1060-1100, purchase.returns.* 1120-1160;
     (module Inventory) inventory.shortages.view 950.  Manager gets the .view ones.

   Requires 19 and 20. Idempotent.
   ===================================================================================== */

IF OBJECT_ID(N'inventory.usp_Item_ApplyReceipts', N'P') IS NULL OR TYPE_ID(N'inventory.tvp_ItemReceipt') IS NULL
BEGIN
    RAISERROR ('Run scripts 19 and 20 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'purchase') IS NULL EXEC (N'CREATE SCHEMA purchase AUTHORIZATION dbo');
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'purchase.PurchaseDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocuments
    (
        Id                INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId    INT            NOT NULL,     -- PO | PINV | PRET
        DocumentNumber    NVARCHAR(30)   NULL,
        DocumentDate      DATE           NOT NULL,
        ExpectedDate      DATE           NULL,         -- PO: expected delivery; PINV: due date
        BranchId          INT            NOT NULL,
        WarehouseId       INT            NOT NULL,
        SupplierId        INT            NOT NULL,     -- masterdata.Parties (IsSupplier) - name matters: party type guard
        CurrencyId        INT            NOT NULL,
        RateType          TINYINT        NOT NULL CONSTRAINT DF_PurchaseDocuments_RateType DEFAULT (1),
        ExchangeRate      DECIMAL(18,6)  NOT NULL CONSTRAINT DF_PurchaseDocuments_Rate DEFAULT (1),
        SupplierReference NVARCHAR(100)  NULL,         -- supplier's order / invoice number
        Notes             NVARCHAR(1000) NULL,
        Status            TINYINT        NOT NULL CONSTRAINT DF_PurchaseDocuments_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled, 4 Closed (PO)
        TotalItems        INT            NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalItems DEFAULT (0),
        TotalQuantity     INT            NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalQuantity DEFAULT (0),
        Subtotal          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_Subtotal DEFAULT (0),
        TotalDiscount     DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalDiscount DEFAULT (0),
        TotalAmount       DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalAmount DEFAULT (0),      -- document currency
        TotalAmountBase   DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PurchaseDocuments_TotalAmountBase DEFAULT (0),  -- base currency
        SourceDocumentId  INT            NULL,         -- PINV <- PO, PRET <- PINV
        PostedAtUtc       DATETIME2(3)   NULL,
        PostedBy          INT            NULL,
        CancelledAtUtc    DATETIME2(3)   NULL,
        CancelledBy       INT            NULL,
        CancelReason      NVARCHAR(300)  NULL,
        ClosedAtUtc       DATETIME2(3)   NULL,
        ClosedBy          INT            NULL,
        CloseReason       NVARCHAR(300)  NULL,
        CreatedAtUtc      DATETIME2(3)   NOT NULL CONSTRAINT DF_PurchaseDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy         INT            NULL,
        UpdatedAtUtc      DATETIME2(3)   NULL,
        UpdatedBy         INT            NULL,
        RowVersion        ROWVERSION     NOT NULL,
        CONSTRAINT PK_PurchaseDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_PurchaseDocuments_Status CHECK (Status IN (1, 2, 3, 4)),
        CONSTRAINT CK_PurchaseDocuments_RateType CHECK (RateType IN (1, 2, 3)),
        CONSTRAINT CK_PurchaseDocuments_Rate CHECK (ExchangeRate > 0),
        CONSTRAINT FK_PurchaseDocuments_Type        FOREIGN KEY (DocumentTypeId)   REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_PurchaseDocuments_Branch      FOREIGN KEY (BranchId)         REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_PurchaseDocuments_Warehouse   FOREIGN KEY (WarehouseId)      REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_PurchaseDocuments_Supplier    FOREIGN KEY (SupplierId)       REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_PurchaseDocuments_Currency    FOREIGN KEY (CurrencyId)       REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_PurchaseDocuments_Source      FOREIGN KEY (SourceDocumentId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseDocuments_CreatedBy   FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_UpdatedBy   FOREIGN KEY (UpdatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_PostedBy    FOREIGN KEY (PostedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_CancelledBy FOREIGN KEY (CancelledBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseDocuments_ClosedBy    FOREIGN KEY (ClosedBy)         REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_PurchaseDocuments_Number ON purchase.PurchaseDocuments (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_TypeDate   ON purchase.PurchaseDocuments (DocumentTypeId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_TypeStatus ON purchase.PurchaseDocuments (DocumentTypeId, Status);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_Supplier   ON purchase.PurchaseDocuments (SupplierId, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocuments_Source     ON purchase.PurchaseDocuments (SourceDocumentId) WHERE SourceDocumentId IS NOT NULL;
    PRINT 'Created purchase.PurchaseDocuments';
END
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocumentLines
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        DocumentId           INT           NOT NULL,
        LineNumber           INT           NOT NULL,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,
        WarehouseId          INT           NOT NULL,
        ExpiryDate           DATE          NULL,
        Quantity             INT           NOT NULL,
        PackingFormula       INT           NOT NULL,
        QuantityBase         AS (Quantity * PackingFormula) PERSISTED,
        UnitPrice            DECIMAL(18,4) NOT NULL,          -- per unit, document currency
        DiscountPercent      DECIMAL(9,4)  NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Discount DEFAULT (0),
        LineDiscount         AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * DiscountPercent / 100.0)) PERSISTED,
        LineTotal            AS (CONVERT(DECIMAL(18,2), Quantity * UnitPrice * (1 - DiscountPercent / 100.0))) PERSISTED,
        UnitCostBase         DECIMAL(18,6) NULL,              -- per BASE unit, base currency (set at posting)
        ReceivedQuantityBase INT           NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Received DEFAULT (0),  -- PO lines: invoiced so far
        ReturnedQuantityBase INT           NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Returned DEFAULT (0),  -- PINV lines: returned so far
        ImportRowNumber      INT           NULL,
        Notes                NVARCHAR(300) NULL,
        SourceLineId         INT           NULL,
        CONSTRAINT PK_PurchaseDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT CK_PurchaseDocumentLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_PurchaseDocumentLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_PurchaseDocumentLines_Price CHECK (UnitPrice >= 0),
        CONSTRAINT CK_PurchaseDocumentLines_Discount CHECK (DiscountPercent BETWEEN 0 AND 100),
        CONSTRAINT FK_PurchaseDocumentLines_Document   FOREIGN KEY (DocumentId)   REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseDocumentLines_Item       FOREIGN KEY (ItemId)       REFERENCES inventory.Items (Id),
        CONSTRAINT FK_PurchaseDocumentLines_ItemUnit   FOREIGN KEY (ItemUnitId)   REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_PurchaseDocumentLines_Warehouse  FOREIGN KEY (WarehouseId)  REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_PurchaseDocumentLines_SourceLine FOREIGN KEY (SourceLineId) REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_Document ON purchase.PurchaseDocumentLines (DocumentId);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_Item     ON purchase.PurchaseDocumentLines (ItemId);
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_Source   ON purchase.PurchaseDocumentLines (SourceLineId) WHERE SourceLineId IS NOT NULL;
    PRINT 'Created purchase.PurchaseDocumentLines';
END
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocumentFiles
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        DocumentId   INT            NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_PurchaseDocumentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_PurchaseDocumentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_PurchaseDocumentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_PurchaseDocumentFiles_Document  FOREIGN KEY (DocumentId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseDocumentFiles_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentFiles_Document ON purchase.PurchaseDocumentFiles (DocumentId);
    PRINT 'Created purchase.PurchaseDocumentFiles';
END
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Imported | Posted | Cancelled | Closed | FileAdded | FileDeleted
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_PurchaseDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_PurchaseDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_PurchaseDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentAudit_Document ON purchase.PurchaseDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created purchase.PurchaseDocumentAudit';
END
GO

IF TYPE_ID(N'purchase.tvp_PurchaseDocumentLine') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PurchaseDocumentLine AS TABLE
    (
        LineNumber      INT           NOT NULL PRIMARY KEY,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        WarehouseId     INT           NOT NULL,       -- ignored: the header warehouse is used
        ExpiryDate      DATE          NULL,
        Quantity        INT           NOT NULL,
        UnitPrice       DECIMAL(18,4) NULL,           -- NULL = item last cost converted to the document currency (0 when none)
        DiscountPercent DECIMAL(9,4)  NULL,
        ImportRowNumber INT           NULL,
        Notes           NVARCHAR(300) NULL,
        SourceLineId    INT           NULL            -- PO line (for PINV) / PINV line (for PRET)
    );
    PRINT 'Created type purchase.tvp_PurchaseDocumentLine';
END
GO

/* ================================================================== 2. Rate helper (any currency) */

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Resolve
    @CurrencyId INT,
    @RateType   TINYINT = 1,
    @AsOfDate   DATE    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    SELECT c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(c.Id, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.Currencies c
    WHERE c.Id = @CurrencyId;
END
GO

/* ================================================================== 3. Search / Get */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,     -- PO | PINV | PRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, supplier reference, supplier code/name, notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @SupplierId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled | 4 Closed
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | SupplierName | Status | TotalAmount | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.SupplierReference, d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND d.TotalQuantity > 0
                                  THEN CAST(100.0 * (SELECT SUM(ReceivedQuantityBase) FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) / d.TotalQuantity AS DECIMAL(5,1)) END,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc, d.ClosedAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Purchase'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.SupplierReference LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Five result sets: header, lines, files, audit, linked documents (source + children).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, l.ReceivedQuantityBase, l.ReturnedQuantityBase,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- Linked documents: the source (Relation = 'Source') and everything created from this one (Relation = 'Child').
    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;
END
GO

/* ================================================================== 4. Validation helper */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE,
    @BranchId           INT,
    @WarehouseId        INT,
    @SupplierId         INT,
    @CurrencyId         INT,             -- NULL = supplier default currency, else base
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),   -- NULL = resolve
    @MaxDiscountPercent DECIMAL(9,4),
    @SourceDocumentId   INT,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @ResolvedCurrencyId INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Purchase' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 65008, 'Document type not found, inactive, or not a purchase document.', 1;

    IF @DocumentDate IS NULL THROW 65000, 'Document Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 65000, 'Document Date cannot be in the future.', 1;
    IF @ExpectedDate IS NOT NULL AND @ExpectedDate < @DocumentDate THROW 65000, 'Expected / due date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 65008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 65008, 'The warehouse must be an active warehouse of the selected branch.', 1;
    IF @SupplierId IS NULL THROW 65000, 'Supplier is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 65008, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    SET @ResolvedCurrencyId = COALESCE(@CurrencyId,
                                       (SELECT DefaultCurrencyId FROM masterdata.Parties WHERE Id = @SupplierId),
                                       (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1));
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsActive = 1)
        THROW 65008, 'Currency not found or inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 65000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 65000, 'Exchange rate must be greater than zero.', 1;
    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@ResolvedCurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 65008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    -- Source document rules.
    IF @SourceDocumentId IS NOT NULL
    BEGIN
        DECLARE @SrcType NVARCHAR(20), @SrcStatus TINYINT, @SrcSupplier INT, @SrcBranch INT;
        SELECT @SrcType = dt.Code, @SrcStatus = d.Status, @SrcSupplier = d.SupplierId, @SrcBranch = d.BranchId
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceDocumentId;
        IF @SrcType IS NULL THROW 65011, 'Source document not found.', 1;
        IF (@DocumentTypeCode = N'PINV' AND @SrcType <> N'PO') OR (@DocumentTypeCode = N'PRET' AND @SrcType <> N'PINV') OR @DocumentTypeCode = N'PO'
            THROW 65011, 'A purchase invoice can only come from a purchase order and a return from a purchase invoice.', 1;
        IF @SrcStatus <> 2 THROW 65011, 'The source document must be posted (and, for an order, still open).', 1;
        IF @SrcSupplier <> @SupplierId THROW 65011, 'The supplier must be the supplier of the source document.', 1;
        IF @SrcBranch <> @BranchId THROW 65011, 'The branch must be the branch of the source document.', 1;
        IF EXISTS (SELECT 1 FROM @Lines l WHERE l.SourceLineId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines s WHERE s.Id = l.SourceLineId AND s.DocumentId = @SourceDocumentId))
            THROW 65011, 'A line refers to a source line that does not belong to the source document.', 1;
    END

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 65000, @Msg, 1;
END
GO

/* ================================================================== 5. Save (draft) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @SupplierId         INT,
    @CurrencyId         INT            = NULL,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @SupplierReference  NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @SourceDocumentId   INT            = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines: header warehouse; blank price = item last cost (USD per base unit) converted to the document currency per unit.
        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, @WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.UnitCostBase END,      -- returns carry the invoice cost
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Post */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        -- Source consumption checks (posted documents only count).
        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = @Id AND l.LineNumber = x.LineNumber
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = @Id AND l.LineNumber = x.LineNumber
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        -- Returns remove stock: it must be there.
        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- Cost per base unit in the base currency.
        UPDATE l
        SET UnitCostBase = CASE WHEN @TypeCode = N'PRET' THEN ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
                                ELSE (l.UnitPrice * (1 - l.DiscountPercent / 100.0)) / l.PackingFormula / @Rate END
        FROM purchase.PurchaseDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0) FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        -- Consume the source: PO received quantities (close the PO when everything is in) / PINV returned quantities.
        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N' (order confirmed)' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Cancel / Close / Delete */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId, @Number = d.DocumentNumber
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Nothing may still depend on this document.
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;

        DECLARE @Msg NVARCHAR(400);
        IF @Direction = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentId = @Id AND m.IsReversal = 0;

        -- Give the source its quantities back (and re-open a PO that this invoice had closed).
        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason = N'Fully received')
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Purchase orders only: stop receiving against an open order.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders can be closed.', 1;
    IF @Status <> 2 THROW 65010, 'Only open (posted) purchase orders can be closed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    UPDATE purchase.PurchaseDocuments
    SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = ISNULL(NULLIF(LTRIM(RTRIM(@Reason)), N''), N'Closed manually'),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Closed', ISNULL(@Reason, N'Closed manually'), @UserId);
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 1 THROW 65005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. Conversions: PO -> PINV, PINV -> PRET (drafts) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromSource
    @SourceId       INT,
    @TargetTypeCode NVARCHAR(20),        -- PINV (from PO) | PRET (from PINV)
    @DocumentDate   DATE = NULL,         -- default today
    @UserId         INT  = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT, @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;

    IF @SrcType IS NULL THROW 65006, 'Source document not found.', 1;
    IF @Status <> 2 THROW 65011, 'The source document must be posted and still open.', 1;
    IF NOT ((@TargetTypeCode = N'PINV' AND @SrcType = N'PO') OR (@TargetTypeCode = N'PRET' AND @SrcType = N'PINV'))
        THROW 65011, 'Purchase orders become purchase invoices; purchase invoices become purchase returns.', 1;

    -- Remaining quantity per line; when it is not a whole number of the line's unit, the new line uses the BASE unit
    -- (price converted per base unit) so nothing is over-received or over-returned.
    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate,
           c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes, l.Id
    FROM purchase.PurchaseDocumentLines l
    CROSS APPLY (SELECT Remaining = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE l.QuantityBase - l.ReturnedQuantityBase END) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;

    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 65011, 'Nothing remains to receive / return on the source document.', 1;

    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = @TargetTypeCode, @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
         @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;
END
GO

/* ================================================================== 9. Attachments */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Add
    @DocumentId INT, @FileName NVARCHAR(255), @ContentType NVARCHAR(100), @SizeBytes INT, @Content VARBINARY(MAX),
    @UserId INT = NULL, @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId) THROW 65006, 'Document not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 65000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 65000, 'The file is empty.', 1;

    INSERT INTO purchase.PurchaseDocumentFiles (DocumentId, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@DocumentId, LTRIM(RTRIM(@FileName)), @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileAdded', LTRIM(RTRIM(@FileName)), @UserId);
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocumentFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DocumentId INT, @Name NVARCHAR(255);
    SELECT @DocumentId = DocumentId, @Name = FileName FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    IF @DocumentId IS NULL THROW 65006, 'File not found.', 1;
    DELETE FROM purchase.PurchaseDocumentFiles WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@DocumentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 10. Shortages report */

CREATE OR ALTER PROCEDURE inventory.usp_Shortage_Report
    @BranchId       INT           = NULL,
    @WarehouseId    INT           = NULL,
    @ItemFamilyId   INT           = NULL,
    @BrandId        INT           = NULL,
    @SupplierId     INT           = NULL,     -- default supplier (else last supplier)
    @Search         NVARCHAR(200) = NULL,     -- item code / name
    @OnlyShortages  BIT           = 1,        -- 1 = rows where Available < Min; 0 = every evaluated item + warehouse
    @DaysForAverage INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @DaysForAverage IS NULL OR @DaysForAverage < 1 SET @DaysForAverage = 30;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@DaysForAverage, SYSUTCDATETIME());

    ;WITH pairs AS
    (
        SELECT i.Id AS ItemId, i.DefaultWarehouseId AS WarehouseId FROM inventory.Items i WHERE i.IsActive = 1
        UNION
        SELECT m.ItemId, m.WarehouseId FROM inventory.StockMovements m INNER JOIN inventory.Items i ON i.Id = m.ItemId WHERE i.IsActive = 1
    ),
    base AS
    (
        SELECT p.ItemId, p.WarehouseId,
               OnHandBase   = inventory.fn_StockOnHand(p.ItemId, p.WarehouseId),
               IncomingBase = ISNULL((SELECT SUM(l.QuantityBase - l.ReceivedQuantityBase)
                                      FROM purchase.PurchaseDocumentLines l
                                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                                      INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                                      WHERE dt.Code = N'PO' AND d.Status = 2 AND l.ItemId = p.ItemId AND l.WarehouseId = p.WarehouseId
                                        AND l.QuantityBase > l.ReceivedQuantityBase), 0),
               SoldBase     = ISNULL((SELECT SUM(-m.QuantityBase) FROM inventory.StockMovements m
                                      WHERE m.ItemId = p.ItemId AND m.WarehouseId = p.WarehouseId AND m.DocumentFamily = N'Sales' AND m.MovementDate >= @Since), 0)
        FROM pairs p
    )
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.ItemFamilyId, f.FamilyName, i.IsBivac,
           w.Id AS WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId, br.BranchName,
           x.OnHandBase, x.IncomingBase, AvailableBase = x.OnHandBase + x.IncomingBase,
           i.MinQuantity, i.MaxQuantity,
           ShortageBase  = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN i.MinQuantity - (x.OnHandBase + x.IncomingBase) ELSE 0 END,
           SuggestedBase = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN ISNULL(i.MaxQuantity, i.MinQuantity) - (x.OnHandBase + x.IncomingBase) ELSE 0 END,
           PurchaseItemUnitId = pu.Id, PurchaseUnitName = put.UnitTypeName, PurchasePackingFormula = pu.PackingFormula,
           SuggestedQty  = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity
                                THEN CEILING(CAST(ISNULL(i.MaxQuantity, i.MinQuantity) - (x.OnHandBase + x.IncomingBase) AS DECIMAL(18,4)) / pu.PackingFormula) ELSE 0 END,
           AvgDailySalesBase = CAST(x.SoldBase AS DECIMAL(18,2)) / @DaysForAverage,
           DaysOfCover = CASE WHEN x.SoldBase > 0 THEN CAST(x.OnHandBase AS DECIMAL(18,2)) * @DaysForAverage / x.SoldBase END,
           SupplierId = COALESCE(i.DefaultSupplierId, i.LastSupplierId),
           SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN i.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END,
           i.LastCost, i.AverageCost, i.LeadTimeDays, i.LastPurchaseAtUtc
    FROM base x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Brands b ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    INNER JOIN masterdata.Branches br ON br.Id = w.BranchId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = i.LastSupplierId
    OUTER APPLY (SELECT TOP (1) u.Id, u.PackingFormula, u.UnitTypeId FROM inventory.ItemUnits u WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC) pu
    LEFT  JOIN masterdata.UnitTypes put ON put.Id = pu.UnitTypeId
    WHERE w.IsActive = 1
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR w.Id = @WarehouseId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@SupplierId IS NULL OR COALESCE(i.DefaultSupplierId, i.LastSupplierId) = @SupplierId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR x.OnHandBase + x.IncomingBase < i.MinQuantity)
    ORDER BY CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN 0 ELSE 1 END, i.ItemCode, w.WarehouseCode;
END
GO

/* ================================================================== 11. Permissions + demo supplier + report */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'purchase.orders.view',     N'View Purchase Orders',     N'Purchase', N'See purchase orders.',                              1000),
        (N'purchase.orders.create',   N'Create Purchase Orders',   N'Purchase', N'Create and edit draft purchase orders.',            1010),
        (N'purchase.orders.post',     N'Post Purchase Orders',     N'Purchase', N'Confirm purchase orders (assigns the number).',     1020),
        (N'purchase.orders.cancel',   N'Cancel Purchase Orders',   N'Purchase', N'Cancel or close open purchase orders.',             1030),
        (N'purchase.orders.delete',   N'Delete Purchase Orders',   N'Purchase', N'Delete draft purchase orders.',                     1040),
        (N'purchase.invoices.view',   N'View Purchase Invoices',   N'Purchase', N'See purchase invoices.',                            1060),
        (N'purchase.invoices.create', N'Create Purchase Invoices', N'Purchase', N'Create and edit draft purchase invoices.',          1070),
        (N'purchase.invoices.post',   N'Post Purchase Invoices',   N'Purchase', N'Post purchase invoices (adds stock, sets costs).',  1080),
        (N'purchase.invoices.cancel', N'Cancel Purchase Invoices', N'Purchase', N'Cancel posted purchase invoices (stock reversal).', 1090),
        (N'purchase.invoices.delete', N'Delete Purchase Invoices', N'Purchase', N'Delete draft purchase invoices.',                   1100),
        (N'purchase.returns.view',    N'View Purchase Returns',    N'Purchase', N'See purchase returns.',                             1120),
        (N'purchase.returns.create',  N'Create Purchase Returns',  N'Purchase', N'Create and edit draft purchase returns.',           1130),
        (N'purchase.returns.post',    N'Post Purchase Returns',    N'Purchase', N'Post purchase returns (removes stock).',            1140),
        (N'purchase.returns.cancel',  N'Cancel Purchase Returns',  N'Purchase', N'Cancel posted purchase returns (stock reversal).',  1150),
        (N'purchase.returns.delete',  N'Delete Purchase Returns',  N'Purchase', N'Delete draft purchase returns.',                    1160),
        (N'inventory.shortages.view', N'View Shortages',           N'Inventory', N'See the shortage report and create purchase orders from it.', 950)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'purchase.%' OR p.Code = N'inventory.shortages.view')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'purchase.orders.view', N'purchase.invoices.view', N'purchase.returns.view', N'inventory.shortages.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- The seeded supplier becomes the default supplier of items that have none (demo convenience).
UPDATE i SET DefaultSupplierId = s.Id
FROM inventory.Items i
CROSS APPLY (SELECT TOP (1) Id FROM masterdata.Parties WHERE IsSupplier = 1 AND IsActive = 1 ORDER BY Id) s
WHERE i.DefaultSupplierId IS NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE IsSupplier = 1 AND IsActive = 1 AND Id <> s.Id);
GO

-- ===== 22: Shortage planning documents =====

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 22: SHORTAGE planning documents (replaces the live-only shortage report)

   A shortage is now a saved planning document with its own history:
     Draft  - editable, can be recalculated (live figures refreshed, manual values kept), deleted
     Posted - read-only historical SNAPSHOT (nothing is recalculated when viewed); purchase orders are created
              from it and carry the Shortage No. (Shortage -> PO -> Purchase Invoice traceability)
   One document = one warehouse (quantities), one branch (for the PO), one supplier (for the PO).

   Rule (per line, base units):
     Stock + Transit          = Current Inventory + Transit Qty
     Total Expected Stock     = Current Inventory + Transit Qty + Outstanding Order Qty
     Expected Requirement     = Expected Monthly Sales x Lead Time (Month)
     Shortage Qty             = max(0, Expected Requirement - Total Expected Stock)
     Coverage (months)        = Total Expected Stock / Expected Monthly Sales
     Container Requirement    = Required Qty (purchase unit) x packing / PC per Container
   Sources:
     Current Inventory     = stock ledger on hand in the warehouse
     Outstanding Order Qty = open purchase-order lines for the warehouse: remaining - in transit
     Transit Qty           = shipped but not yet received on those lines (NEW: purchase.usp_PurchaseDocument_MarkShipped
                             sets ShippedQuantityBase until the Shipment module exists)
     Expected Monthly Sales = net Sales-family outflow of the last "Months of history" months in the warehouse / months,
                             overridable per line (ExpectedMonthlySalesManual)
     PC per Container      = inventory.Items.PcPerContainer (NEW), overridable per line
     Required Qty          = manual, in the item's PURCHASE unit; default = shortage rounded up to that unit

   Objects:
     inventory.DocumentTypes  + YearInNumber, NextNumberYear; type SHR (prefix SHR-, year in number: SHR-2026-000001)
     inventory.DocumentSequences + Year (per branch AND year sequences); usp_DocumentType_NextNumber / _List / _Update re-created
     inventory.Items          + PcPerContainer; usp_Item_Get / usp_Item_SetPurchasing re-created
     purchase.PurchaseDocumentLines + ShippedQuantityBase; purchase.PurchaseDocuments + SourceShortageId;
     purchase.tvp_ShippedLine, usp_PurchaseDocument_MarkShipped; usp_PurchaseDocument_Get re-created (transit + shortage link)
     inventory.ShortageDocuments / ShortageDocumentLines / ShortageDocumentAudit, tvp_ShortageLine
     inventory.fn_Shortage_Live (the live figures for one warehouse), usp_Shortage_Calculate (live rows for the page),
     usp_ShortageDocument_Search / _Get / _Save / _Recalculate / _Post / _Delete / _CreatePurchaseOrder
     (inventory.usp_Shortage_Report of script 21 is DROPPED - the API switches to usp_Shortage_Calculate)
   Errors 66xxx: 66000 validation, 66004 concurrency, 66005 not a draft, 66006 not found, 66009 no lines,
                 66010 invalid status, 66011 nothing to order
   Permissions (module Inventory): inventory.shortages.view 950 / create 960 / post 970 / delete 980

   Requires 19, 20, 21. Idempotent.
   ===================================================================================== */
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentLines', N'U') IS NULL OR OBJECT_ID(N'inventory.DocumentSequences', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 19, 20 and 21 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Numbering: year segment */

IF COL_LENGTH(N'inventory.DocumentTypes', N'YearInNumber') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        YearInNumber   BIT NOT NULL CONSTRAINT DF_DocumentTypes_YearInNumber DEFAULT (0),
        NextNumberYear INT NULL;
    PRINT 'DocumentTypes: added YearInNumber, NextNumberYear';
END
GO

IF COL_LENGTH(N'inventory.DocumentSequences', N'Year') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentSequences DROP CONSTRAINT PK_DocumentSequences;
    ALTER TABLE inventory.DocumentSequences ADD [Year] INT NOT NULL CONSTRAINT DF_DocumentSequences_Year DEFAULT (0);
    ALTER TABLE inventory.DocumentSequences ADD CONSTRAINT PK_DocumentSequences PRIMARY KEY CLUSTERED (DocumentTypeId, BranchId, [Year]);
    PRINT 'DocumentSequences: sequences are now per type + branch + year';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'SHR', N'Shortage Plan', N'Inventory', 0, N'SHR-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

UPDATE inventory.DocumentTypes SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 0, YearInNumber = 1 WHERE Code = N'SHR';
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_Update
    @Id              INT,
    @Name            NVARCHAR(100),
    @NumberPrefix    NVARCHAR(10),
    @NumberLength    TINYINT,
    @NumberOnPost    BIT,
    @RequiresReason  BIT,
    @DefaultPricing  NVARCHAR(10),
    @PriceEditable   BIT,
    @NumberPerBranch BIT,
    @IsActive        BIT,
    @RowVersion      BINARY(8) = NULL,
    @UserId          INT       = NULL,
    @YearInNumber    BIT       = NULL     -- NULL = unchanged
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @NumberPrefix = NULLIF(LTRIM(RTRIM(@NumberPrefix)), N'');
    IF @Name IS NULL THROW 62000, 'Name is required.', 1;
    IF @NumberPrefix IS NULL THROW 62000, 'Number prefix is required.', 1;
    IF @NumberLength IS NULL OR @NumberLength NOT BETWEEN 3 AND 10 THROW 62000, 'Number length must be between 3 and 10.', 1;
    IF @DefaultPricing NOT IN (N'Cost', N'PriceList', N'None') THROW 62000, 'Default pricing must be Cost, PriceList or None.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id) THROW 62006, 'Document type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 62004, 'This document type was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.DocumentTypes
    SET Name = @Name, NumberPrefix = @NumberPrefix, NumberLength = @NumberLength, NumberOnPost = ISNULL(@NumberOnPost, 0),
        RequiresReason = ISNULL(@RequiresReason, 0), DefaultPricing = @DefaultPricing, PriceEditable = ISNULL(@PriceEditable, 1),
        NumberPerBranch = ISNULL(@NumberPerBranch, 1), YearInNumber = ISNULL(@YearInNumber, YearInNumber), IsActive = ISNULL(@IsActive, 1),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Prefix [+ branch code + '-'] [+ year + '-'] + zero-padded sequence.  SHR-2026-000001 / INV-KLW-000001 / IN-000001.
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT,
    @BranchId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId INT, @Prefix NVARCHAR(10), @Len TINYINT, @PerBranch BIT, @YearIn BIT;
    SELECT @TypeId = Id, @Prefix = NumberPrefix, @Len = NumberLength, @PerBranch = NumberPerBranch, @YearIn = YearInNumber
    FROM inventory.DocumentTypes WHERE Code = @Code AND IsActive = 1;
    IF @TypeId IS NULL THROW 62008, 'Document type not found or inactive.', 1;

    DECLARE @Year INT = YEAR(SYSUTCDATETIME());
    DECLARE @SeqYear INT = CASE WHEN @YearIn = 1 THEN @Year ELSE 0 END;
    DECLARE @Taken TABLE (Number INT);
    DECLARE @Middle NVARCHAR(20) = N'';

    IF @PerBranch = 1 AND @BranchId IS NOT NULL
    BEGIN
        DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
        IF @BranchCode IS NULL THROW 62008, 'Branch not found.', 1;

        MERGE inventory.DocumentSequences WITH (HOLDLOCK) AS t
        USING (SELECT @TypeId AS DocumentTypeId, @BranchId AS BranchId, @SeqYear AS [Year]) AS s
            ON t.DocumentTypeId = s.DocumentTypeId AND t.BranchId = s.BranchId AND t.[Year] = s.[Year]
        WHEN MATCHED THEN UPDATE SET NextNumber = t.NextNumber + 1
        WHEN NOT MATCHED THEN INSERT (DocumentTypeId, BranchId, [Year], NextNumber) VALUES (s.DocumentTypeId, s.BranchId, s.[Year], 2)
        OUTPUT ISNULL(deleted.NextNumber, 1) INTO @Taken (Number);

        SET @Middle = UPPER(LEFT(@BranchCode, 8)) + N'-';
    END
    ELSE
    BEGIN
        UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
        SET NextNumber     = CASE WHEN @YearIn = 1 AND ISNULL(NextNumberYear, 0) <> @Year THEN 2 ELSE NextNumber + 1 END,
            NextNumberYear = CASE WHEN @YearIn = 1 THEN @Year ELSE NextNumberYear END
        OUTPUT CASE WHEN @YearIn = 1 AND ISNULL(deleted.NextNumberYear, 0) <> @Year THEN 1 ELSE deleted.NextNumber END INTO @Taken (Number)
        WHERE Id = @TypeId;
    END

    IF @YearIn = 1 SET @Middle = @Middle + CAST(@Year AS NVARCHAR(4)) + N'-';

    SELECT @DocumentNumber = @Prefix + @Middle + RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len) FROM @Taken;
END
GO

/* ================================================================== 2. Items: PC per container */

IF COL_LENGTH(N'inventory.Items', N'PcPerContainer') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD PcPerContainer INT NULL CONSTRAINT CK_Items_PcPerContainer CHECK (PcPerContainer IS NULL OR PcPerContainer > 0);
    PRINT 'Items: added PcPerContainer';
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT = NULL,
    @LeadTimeDays      INT = NULL,
    @UserId            INT = NULL,
    @PcPerContainer    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @PcPerContainer IS NOT NULL AND @PcPerContainer <= 0 THROW 56000, 'PC per container must be greater than zero.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, PcPerContainer = @PcPerContainer,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = (SELECT TOP (1) CAST(m.UnitCostBase AS DECIMAL(18,2)) FROM inventory.StockMovements m
                               WHERE m.ItemId = i.Id AND m.DocumentFamily = N'Purchase' AND m.QuantityBase > 0 AND m.IsReversal = 0
                               ORDER BY m.MovementDate DESC, m.Id DESC),
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays, i.PcPerContainer,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 3. Purchase: transit (shipped) quantities + shortage link */

IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ShippedQuantityBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocumentLines ADD ShippedQuantityBase INT NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Shipped DEFAULT (0);
    PRINT 'PurchaseDocumentLines: added ShippedQuantityBase';
END
GO

IF TYPE_ID(N'purchase.tvp_ShippedLine') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_ShippedLine AS TABLE
    (
        LineId              INT NOT NULL PRIMARY KEY,
        ShippedQuantityBase INT NOT NULL      -- total shipped so far on that line (base units), 0..QuantityBase
    );
    PRINT 'Created type purchase.tvp_ShippedLine';
END
GO

-- Records what the supplier has shipped (in transit) on an OPEN purchase order. NULL/empty @Lines = everything shipped.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_MarkShipped
    @Id         INT,
    @Lines      purchase.tvp_ShippedLine READONLY,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' OR @Status <> 2 THROW 65010, 'Shipped quantities can only be recorded on an open (posted) purchase order.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM @Lines s LEFT JOIN purchase.PurchaseDocumentLines l ON l.Id = s.LineId AND l.DocumentId = @Id
               WHERE l.Id IS NULL OR s.ShippedQuantityBase < 0 OR s.ShippedQuantityBase > l.QuantityBase)
        THROW 65000, 'A shipped quantity is negative, above the ordered quantity, or refers to a line of another document.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF EXISTS (SELECT 1 FROM @Lines)
            UPDATE l SET ShippedQuantityBase = s.ShippedQuantityBase
            FROM purchase.PurchaseDocumentLines l INNER JOIN @Lines s ON s.LineId = l.Id;
        ELSE
            UPDATE purchase.PurchaseDocumentLines SET ShippedQuantityBase = QuantityBase WHERE DocumentId = @Id;

        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Shipped quantities recorded: ' + CAST((SELECT SUM(ShippedQuantityBase) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) AS NVARCHAR(20)) + N' base unit(s) in transit', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 4. Shortage documents */

IF OBJECT_ID(N'inventory.ShortageDocuments', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ShortageDocuments
    (
        Id                      INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId          INT            NOT NULL,     -- SHR
        DocumentNumber          NVARCHAR(30)   NOT NULL,     -- SHR-2026-000001 (assigned at creation)
        Description             NVARCHAR(200)  NOT NULL,
        DocumentDate            DATE           NOT NULL,
        BranchId                INT            NOT NULL,     -- for the purchase order
        WarehouseId             INT            NOT NULL,     -- quantities are computed here
        SupplierId              INT            NOT NULL,     -- for the purchase order
        LeadTimeMonths          DECIMAL(6,2)   NOT NULL,     -- "Lead Time (Month)"
        MonthsOfHistory         INT            NOT NULL CONSTRAINT DF_ShortageDocuments_History DEFAULT (3),   -- months used for Expected Monthly Sales
        Notes                   NVARCHAR(1000) NULL,
        Status                  TINYINT        NOT NULL CONSTRAINT DF_ShortageDocuments_Status DEFAULT (1),   -- 1 Draft, 2 Posted
        TotalLines              INT            NOT NULL CONSTRAINT DF_ShortageDocuments_Lines DEFAULT (0),
        TotalShortageBase       INT            NOT NULL CONSTRAINT DF_ShortageDocuments_Shortage DEFAULT (0),
        TotalRequiredBase       INT            NOT NULL CONSTRAINT DF_ShortageDocuments_Required DEFAULT (0),
        TotalContainers         DECIMAL(9,2)   NOT NULL CONSTRAINT DF_ShortageDocuments_Containers DEFAULT (0),   -- sum of container requirements
        ContainersRounded       INT            NOT NULL CONSTRAINT DF_ShortageDocuments_ContainersRounded DEFAULT (0),
        ContainerUtilizationPct DECIMAL(5,2)   NULL,
        CalculatedAtUtc         DATETIME2(3)   NULL,         -- last time the live figures were taken
        PostedAtUtc             DATETIME2(3)   NULL,
        PostedBy                INT            NULL,
        CreatedAtUtc            DATETIME2(3)   NOT NULL CONSTRAINT DF_ShortageDocuments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy               INT            NULL,
        UpdatedAtUtc            DATETIME2(3)   NULL,
        UpdatedBy               INT            NULL,
        RowVersion              ROWVERSION     NOT NULL,
        CONSTRAINT PK_ShortageDocuments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ShortageDocuments_Number UNIQUE (DocumentNumber),
        CONSTRAINT CK_ShortageDocuments_Status CHECK (Status IN (1, 2)),
        CONSTRAINT CK_ShortageDocuments_LeadTime CHECK (LeadTimeMonths > 0),
        CONSTRAINT CK_ShortageDocuments_History CHECK (MonthsOfHistory BETWEEN 1 AND 36),
        CONSTRAINT FK_ShortageDocuments_Type      FOREIGN KEY (DocumentTypeId) REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_ShortageDocuments_Branch    FOREIGN KEY (BranchId)       REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_ShortageDocuments_Warehouse FOREIGN KEY (WarehouseId)    REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_ShortageDocuments_Supplier  FOREIGN KEY (SupplierId)     REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_ShortageDocuments_PostedBy  FOREIGN KEY (PostedBy)       REFERENCES security.Users (Id),
        CONSTRAINT FK_ShortageDocuments_CreatedBy FOREIGN KEY (CreatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_ShortageDocuments_UpdatedBy FOREIGN KEY (UpdatedBy)      REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ShortageDocuments_Date      ON inventory.ShortageDocuments (DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_ShortageDocuments_Warehouse ON inventory.ShortageDocuments (WarehouseId, Status);
    CREATE NONCLUSTERED INDEX IX_ShortageDocuments_Supplier  ON inventory.ShortageDocuments (SupplierId);
    PRINT 'Created inventory.ShortageDocuments';
END
GO

IF OBJECT_ID(N'inventory.ShortageDocumentLines', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ShortageDocumentLines
    (
        Id                        INT IDENTITY(1,1) NOT NULL,
        DocumentId                INT           NOT NULL,
        LineNumber                INT           NOT NULL,
        ItemId                    INT           NOT NULL,
        -- snapshot of the live figures (base units)
        CurrentInventoryBase      INT           NOT NULL,
        TransitBase               INT           NOT NULL,
        OutstandingOrderBase      INT           NOT NULL,
        ExpectedMonthlySalesBase  DECIMAL(18,2) NOT NULL,      -- computed from history
        ExpectedMonthlySalesManual DECIMAL(18,2) NULL,         -- user override
        LeadTimeMonths            DECIMAL(6,2)  NOT NULL,      -- copied from the header (needed by the computed columns)
        -- derived (never recalculated on read)
        StockPlusTransitBase      AS (CurrentInventoryBase + TransitBase) PERSISTED,
        TotalExpectedStockBase    AS (CurrentInventoryBase + TransitBase + OutstandingOrderBase) PERSISTED,
        EffectiveMonthlySales     AS (ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase)) PERSISTED,
        ExpectedRequirementBase   AS (CONVERT(DECIMAL(18,2), ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths)) PERSISTED,
        ShortageBase              AS (CASE WHEN ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths - (CurrentInventoryBase + TransitBase + OutstandingOrderBase) > 0
                                           THEN CONVERT(INT, CEILING(ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths - (CurrentInventoryBase + TransitBase + OutstandingOrderBase)))
                                           ELSE 0 END) PERSISTED,
        CoverageMonths            AS (CASE WHEN ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) > 0
                                           THEN CONVERT(DECIMAL(9,2), (CurrentInventoryBase + TransitBase + OutstandingOrderBase) / ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase)) END) PERSISTED,
        -- ordering
        PurchaseItemUnitId        INT           NOT NULL,
        PurchasePackingFormula    INT           NOT NULL,
        RequiredQty               INT           NOT NULL CONSTRAINT DF_ShortageDocumentLines_Required DEFAULT (0),   -- purchase unit, manual
        RequiredBase              AS (RequiredQty * PurchasePackingFormula) PERSISTED,
        PcPerContainer            INT           NULL,
        ContainerRequirement      AS (CASE WHEN PcPerContainer > 0 THEN CONVERT(DECIMAL(9,2), RequiredQty * PurchasePackingFormula * 1.0 / PcPerContainer) END) PERSISTED,
        -- info snapshot
        MinQuantity               INT           NULL,
        MaxQuantity               INT           NULL,
        LastCost                  DECIMAL(18,6) NULL,
        Notes                     NVARCHAR(300) NULL,
        CONSTRAINT PK_ShortageDocumentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ShortageDocumentLines_LineNo UNIQUE (DocumentId, LineNumber),
        CONSTRAINT UQ_ShortageDocumentLines_Item UNIQUE (DocumentId, ItemId),
        CONSTRAINT CK_ShortageDocumentLines_Required CHECK (RequiredQty >= 0),
        CONSTRAINT CK_ShortageDocumentLines_Container CHECK (PcPerContainer IS NULL OR PcPerContainer > 0),
        CONSTRAINT CK_ShortageDocumentLines_Sales CHECK (ExpectedMonthlySalesManual IS NULL OR ExpectedMonthlySalesManual >= 0),
        CONSTRAINT FK_ShortageDocumentLines_Document FOREIGN KEY (DocumentId)         REFERENCES inventory.ShortageDocuments (Id),
        CONSTRAINT FK_ShortageDocumentLines_Item     FOREIGN KEY (ItemId)             REFERENCES inventory.Items (Id),
        CONSTRAINT FK_ShortageDocumentLines_Unit     FOREIGN KEY (PurchaseItemUnitId) REFERENCES inventory.ItemUnits (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ShortageDocumentLines_Document ON inventory.ShortageDocumentLines (DocumentId);
    PRINT 'Created inventory.ShortageDocumentLines';
END
GO

IF OBJECT_ID(N'inventory.ShortageDocumentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ShortageDocumentAudit
    (
        Id         BIGINT IDENTITY(1,1) NOT NULL,
        DocumentId INT           NOT NULL,
        Action     NVARCHAR(20)  NOT NULL,   -- Created | Updated | Recalculated | Posted | POCreated
        Details    NVARCHAR(500) NULL,
        UserId     INT           NULL,
        AtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_ShortageDocumentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ShortageDocumentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ShortageDocumentAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ShortageDocumentAudit_Document ON inventory.ShortageDocumentAudit (DocumentId, AtUtc);
    PRINT 'Created inventory.ShortageDocumentAudit';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'SourceShortageId') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD SourceShortageId INT NULL
        CONSTRAINT FK_PurchaseDocuments_Shortage FOREIGN KEY REFERENCES inventory.ShortageDocuments (Id);
    PRINT 'PurchaseDocuments: added SourceShortageId';
END
GO

IF TYPE_ID(N'inventory.tvp_ShortageLine') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ShortageLine AS TABLE
    (
        LineNumber                 INT           NOT NULL PRIMARY KEY,
        ItemId                     INT           NOT NULL,
        RequiredQty                INT           NULL,        -- purchase unit; NULL = suggested (shortage rounded up)
        ExpectedMonthlySalesManual DECIMAL(18,2) NULL,        -- NULL = computed value
        PcPerContainer             INT           NULL,        -- NULL = the item's value
        Notes                      NVARCHAR(300) NULL
    );
    PRINT 'Created type inventory.tvp_ShortageLine';
END
GO

/* ------------------------------------------------------------------ 4a. Live figures (one warehouse) */

IF OBJECT_ID(N'inventory.usp_Shortage_Report', N'P') IS NOT NULL DROP PROCEDURE inventory.usp_Shortage_Report;
GO

CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = i.PcPerContainer,
           CurrentInventoryBase     = inventory.fn_StockOnHand(i.Id, @WarehouseId),
           TransitBase              = ISNULL(po.Transit, 0),
           OutstandingOrderBase     = ISNULL(po.Outstanding, 0),
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), CAST(ISNULL(s.Sold, 0) AS DECIMAL(18,4)) / NULLIF(@MonthsOfHistory, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        SELECT Transit     = SUM(CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END),
               Outstanding = SUM((l.QuantityBase - l.ReceivedQuantityBase)
                                 - CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE dt.Code = N'PO' AND d.Status = 2 AND l.ItemId = i.Id AND l.WarehouseId = @WarehouseId AND l.QuantityBase > l.ReceivedQuantityBase
    ) po
    OUTER APPLY
    (
        SELECT Sold = SUM(-m.QuantityBase)
        FROM inventory.StockMovements m
        WHERE m.ItemId = i.Id AND m.WarehouseId = @WarehouseId AND m.DocumentFamily = N'Sales'
          AND m.MovementDate >= DATEADD(MONTH, -@MonthsOfHistory, CAST(SYSUTCDATETIME() AS DATE))
    ) s
    OUTER APPLY
    (
        SELECT TOP (1) u.Id AS ItemUnitId, u.PackingFormula, t.UnitTypeName
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC
    ) pu
    WHERE i.IsActive = 1
);
GO

-- Live rows for the page ("Load items" on a new/draft document). Supplier filter = default supplier, else last supplier.
CREATE OR ALTER PROCEDURE inventory.usp_Shortage_Calculate
    @WarehouseId     INT,
    @SupplierId      INT           = NULL,
    @LeadTimeMonths  DECIMAL(6,2)  = 6,
    @MonthsOfHistory INT           = 3,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Search          NVARCHAR(200) = NULL,
    @OnlyShortages   BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 SET @LeadTimeMonths = 6;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory < 1 SET @MonthsOfHistory = 3;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;

    SELECT x.ItemId, x.ItemCode, x.ItemName, b.BrandName, f.FamilyName, x.IsBivac,
           x.CurrentInventoryBase, x.TransitBase, x.OutstandingOrderBase,
           StockPlusTransitBase   = x.CurrentInventoryBase + x.TransitBase,
           TotalExpectedStockBase = x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, x.SoldInPeriodBase, MonthsOfHistory = @MonthsOfHistory, LeadTimeMonths = @LeadTimeMonths,
           ExpectedRequirementBase = CONVERT(DECIMAL(18,2), x.ExpectedMonthlySalesBase * @LeadTimeMonths),
           ShortageBase = c.ShortageBase,
           CoverageMonths = CASE WHEN x.ExpectedMonthlySalesBase > 0
                                 THEN CONVERT(DECIMAL(9,2), (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) / x.ExpectedMonthlySalesBase) END,
           x.PurchaseItemUnitId, x.PurchaseUnitName, x.PurchasePackingFormula,
           SuggestedRequiredQty = CASE WHEN c.ShortageBase > 0 THEN CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END,
           PcPerContainer = x.ItemPcPerContainer,
           ContainerRequirement = CASE WHEN x.ItemPcPerContainer > 0 AND c.ShortageBase > 0
                                       THEN CONVERT(DECIMAL(9,2), CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) * x.PurchasePackingFormula * 1.0 / x.ItemPcPerContainer) END,
           x.MinQuantity, x.MaxQuantity, x.LastCost, x.AverageCost, x.LeadTimeDays,
           SupplierId = COALESCE(x.DefaultSupplierId, x.LastSupplierId), SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN x.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END
    FROM inventory.fn_Shortage_Live(@WarehouseId, @MonthsOfHistory) x
    CROSS APPLY (SELECT ShortageBase = CASE WHEN x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase))) ELSE 0 END) c
    INNER JOIN masterdata.Brands b ON b.Id = x.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = x.ItemFamilyId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = x.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = x.LastSupplierId
    WHERE x.PurchaseItemUnitId IS NOT NULL
      AND (@SupplierId IS NULL OR COALESCE(x.DefaultSupplierId, x.LastSupplierId) = @SupplierId)
      AND (@ItemFamilyId IS NULL OR x.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR x.BrandId = @BrandId)
      AND (@Search IS NULL OR x.ItemCode LIKE N'%' + @Search + N'%' OR x.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR c.ShortageBase > 0)
    ORDER BY CASE WHEN c.ShortageBase > 0 THEN 0 ELSE 1 END, c.ShortageBase DESC, x.ItemCode;
END
GO

/* ------------------------------------------------------------------ 4b. Search / Get */

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Search
    @Search        NVARCHAR(100) = NULL,    -- number or description
    @WarehouseId   INT          = NULL,
    @BranchId      INT          = NULL,
    @SupplierId    INT          = NULL,
    @Status        TINYINT      = NULL,     -- 1 Draft | 2 Posted
    @CreatedBy     INT          = NULL,
    @DateFrom      DATE         = NULL,
    @DateTo        DATE         = NULL,
    @SortColumn    NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | Description | WarehouseName | SupplierName | Status | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'DESC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'Description', N'WarehouseName', N'SupplierName', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, d.LeadTimeMonths, d.MonthsOfHistory, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded,
           PurchaseOrders = (SELECT COUNT(*) FROM purchase.PurchaseDocuments p WHERE p.SourceShortageId = d.Id AND p.Status <> 3),
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.Description LIKE N'%' + @Search + N'%')
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@CreatedBy IS NULL OR d.CreatedBy = @CreatedBy)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'Description' THEN d.Description
                             WHEN N'WarehouseName' THEN w.WarehouseName WHEN N'SupplierName' THEN sp.PartyName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'Description' THEN d.Description
                             WHEN N'WarehouseName' THEN w.WarehouseName WHEN N'SupplierName' THEN sp.PartyName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: header, lines (the snapshot), purchase orders created from it, audit.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.LeadTimeMonths, d.MonthsOfHistory, d.Notes, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded, d.ContainerUtilizationPct,
           d.CalculatedAtUtc, d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName, d.RowVersion
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, br.BrandName, f.FamilyName, i.IsBivac,
           l.CurrentInventoryBase, l.TransitBase, l.OutstandingOrderBase, l.StockPlusTransitBase, l.TotalExpectedStockBase,
           l.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, l.EffectiveMonthlySales, l.LeadTimeMonths,
           l.ExpectedRequirementBase, l.ShortageBase, l.CoverageMonths,
           l.PurchaseItemUnitId, ut.UnitTypeName AS PurchaseUnitName, l.PurchasePackingFormula,
           l.RequiredQty, l.RequiredBase, l.PcPerContainer, l.ContainerRequirement,
           l.MinQuantity, l.MaxQuantity, l.LastCost, l.Notes
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.PurchaseItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT p.Id, p.DocumentNumber, p.DocumentDate, p.Status, p.TotalAmount, c.CurrencyCode, p.CreatedAtUtc
    FROM purchase.PurchaseDocuments p
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    WHERE p.SourceShortageId = @Id
    ORDER BY p.CreatedAtUtc;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.ShortageDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ------------------------------------------------------------------ 4c. Save (draft) / Recalculate */

-- Shared: replace the lines of a draft with fresh live figures for the given items (manual values from the TVP).
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_WriteLines
    @Id     INT,
    @Lines  inventory.tvp_ShortageLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @WarehouseId INT, @Months INT, @LeadTime DECIMAL(6,2);
    SELECT @WarehouseId = WarehouseId, @Months = MonthsOfHistory, @LeadTime = LeadTimeMonths FROM inventory.ShortageDocuments WHERE Id = @Id;

    DECLARE @Msg NVARCHAR(300);
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
                          CASE WHEN i.Id IS NULL THEN N'item not found.' WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
                               WHEN l.RequiredQty < 0 THEN N'required quantity cannot be negative.'
                               WHEN l.ExpectedMonthlySalesManual < 0 THEN N'expected monthly sales cannot be negative.'
                               WHEN l.PcPerContainer <= 0 THEN N'PC per container must be greater than zero.' END
    FROM @Lines l LEFT JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR l.RequiredQty < 0 OR l.ExpectedMonthlySalesManual < 0 OR l.PcPerContainer <= 0
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 66000, @Msg, 1;
    IF EXISTS (SELECT ItemId FROM @Lines GROUP BY ItemId HAVING COUNT(*) > 1) THROW 66000, 'An item appears more than once.', 1;

    DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    INSERT INTO inventory.ShortageDocumentLines (DocumentId, LineNumber, ItemId, CurrentInventoryBase, TransitBase, OutstandingOrderBase,
                                                 ExpectedMonthlySalesBase, ExpectedMonthlySalesManual, LeadTimeMonths,
                                                 PurchaseItemUnitId, PurchasePackingFormula, RequiredQty, PcPerContainer,
                                                 MinQuantity, MaxQuantity, LastCost, Notes)
    SELECT @Id, l.LineNumber, l.ItemId, x.CurrentInventoryBase, x.TransitBase, x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, @LeadTime,
           x.PurchaseItemUnitId, x.PurchasePackingFormula,
           RequiredQty = ISNULL(l.RequiredQty,
                                CASE WHEN s.ShortageBase > 0 THEN CEILING(CAST(s.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END),
           ISNULL(l.PcPerContainer, x.ItemPcPerContainer),
           x.MinQuantity, x.MaxQuantity, x.LastCost, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.fn_Shortage_Live(@WarehouseId, @Months) x ON x.ItemId = l.ItemId
    CROSS APPLY (SELECT ShortageBase = CASE WHEN ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * @LeadTime - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * @LeadTime - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase)))
                                            ELSE 0 END) s
    WHERE x.PurchaseItemUnitId IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @Lines l WHERE NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines s WHERE s.DocumentId = @Id AND s.ItemId = l.ItemId))
        THROW 66000, 'An item has no units configured and cannot be planned.', 1;

    UPDATE d
    SET TotalLines = x.Lines, TotalShortageBase = x.Shortage, TotalRequiredBase = x.Required,
        TotalContainers = x.Containers, ContainersRounded = CEILING(x.Containers),
        ContainerUtilizationPct = CASE WHEN x.Containers > 0 THEN CONVERT(DECIMAL(5,2), 100.0 * x.Containers / CEILING(x.Containers)) END,
        CalculatedAtUtc = SYSUTCDATETIME()
    FROM inventory.ShortageDocuments d
    CROSS APPLY (SELECT COUNT(*) AS Lines, ISNULL(SUM(ShortageBase), 0) AS Shortage, ISNULL(SUM(RequiredBase), 0) AS Required,
                        ISNULL(SUM(ContainerRequirement), 0) AS Containers
                 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id) x
    WHERE d.Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Save
    @Id              INT            = NULL,   -- NULL = create (number assigned now)
    @Description     NVARCHAR(200),
    @DocumentDate    DATE,
    @BranchId        INT,
    @WarehouseId     INT,
    @SupplierId      INT,
    @LeadTimeMonths  DECIMAL(6,2),
    @MonthsOfHistory INT            = 3,
    @Notes           NVARCHAR(1000) = NULL,
    @Lines           inventory.tvp_ShortageLine READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @Description IS NULL THROW 66000, 'Description is required.', 1;
    IF @DocumentDate IS NULL THROW 66000, 'Date is required.', 1;
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 THROW 66000, 'Lead Time (Month) must be greater than zero.', 1;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory NOT BETWEEN 1 AND 36 THROW 66000, 'Months of history must be between 1 and 36.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1) THROW 66000, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1) THROW 66000, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
        IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SHR');
            EXEC inventory.usp_DocumentType_NextNumber N'SHR', @Number OUTPUT, @BranchId;

            INSERT INTO inventory.ShortageDocuments (DocumentTypeId, DocumentNumber, Description, DocumentDate, BranchId, WarehouseId, SupplierId,
                                                     LeadTimeMonths, MonthsOfHistory, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @Description, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @LeadTimeMonths, @MonthsOfHistory, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Number, @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.ShortageDocuments
            SET Description = @Description, DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, SupplierId = @SupplierId,
                LeadTimeMonths = @LeadTimeMonths, MonthsOfHistory = @MonthsOfHistory, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Draft only: refresh the live figures of the existing lines; Required Qty, manual sales and PC per container are kept.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Recalculate
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be recalculated.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;

    DECLARE @Lines inventory.tvp_ShortageLine;
    INSERT INTO @Lines (LineNumber, ItemId, RequiredQty, ExpectedMonthlySalesManual, PcPerContainer, Notes)
    SELECT LineNumber, ItemId, RequiredQty, ExpectedMonthlySalesManual, PcPerContainer, Notes
    FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines;
        UPDATE inventory.ShortageDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Recalculated', N'Live figures refreshed', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ------------------------------------------------------------------ 4d. Post / Delete / Create PO */

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66010, 'Only draft shortage documents can be posted.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id)
        THROW 66009, 'The shortage document has no lines. Load items before posting.', 1;

    UPDATE inventory.ShortageDocuments
    SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Posted', N'Snapshot locked', @UserId);
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be deleted.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PurchaseDocuments SET SourceShortageId = NULL WHERE SourceShortageId = @Id;
        DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;
        DELETE FROM inventory.ShortageDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM inventory.ShortageDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Posted only: one draft purchase order (header supplier / branch / warehouse) from the lines with Required Qty > 0.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_CreatePurchaseOrder
    @Id           INT,
    @DocumentDate DATE = NULL,
    @ExpectedDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @Number NVARCHAR(30), @Description NVARCHAR(200);
    SELECT @Status = Status, @BranchId = BranchId, @WarehouseId = WarehouseId, @SupplierId = SupplierId, @Number = DocumentNumber, @Description = Description
    FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 2 THROW 66010, 'Post the shortage document before creating a purchase order from it.', 1;

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, l.PurchaseItemUnitId, @WarehouseId, NULL, l.RequiredQty, NULL, NULL, NULL,
           LEFT(N'Shortage ' + @Number + ISNULL(N' - ' + l.Notes, N''), 300), NULL
    FROM inventory.ShortageDocumentLines l
    WHERE l.DocumentId = @Id AND l.RequiredQty > 0;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 66011, 'No line has a required quantity greater than zero.', 1;

    DECLARE @Notes NVARCHAR(1000) = N'Created from shortage plan ' + @Number + N' - ' + @Description;
    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = N'PO', @DocumentDate = @DocumentDate, @ExpectedDate = @ExpectedDate,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = NULL,
         @RateType = 1, @ExchangeRate = NULL, @SupplierReference = NULL, @Notes = @Notes,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

    UPDATE purchase.PurchaseDocuments SET SourceShortageId = @Id WHERE Id = @NewId;
    INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@Id, N'POCreated', N'Purchase order draft created (' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s))', @UserId);
END
GO

/* ================================================================== 5. purchase.usp_PurchaseDocument_Get re-created (transit + shortage link) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           TransitBase = CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;
END
GO

/* ================================================================== 6. Permissions + report */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'inventory.shortages.view',   N'View Shortage Plans',   N'Inventory', N'See shortage planning documents.',                         950),
        (N'inventory.shortages.create', N'Create Shortage Plans', N'Inventory', N'Create, edit and recalculate draft shortage plans.',       960),
        (N'inventory.shortages.post',   N'Post Shortage Plans',   N'Inventory', N'Post shortage plans (locks the snapshot).',                970),
        (N'inventory.shortages.delete', N'Delete Shortage Plans', N'Inventory', N'Delete draft shortage plans.',                             980)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'inventory.shortages.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'inventory.shortages.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

-- ===== 23: Item costing (FOB, landed cost, charges, profit) =====

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 23: ITEM COSTING (FOB -> landed -> moving average -> frozen COGS -> gross profit)

   Rules implemented (all costs per BASE unit in the base currency):
     FOB cost            = line total after discount / base quantity / exchange rate (purchase invoice line)
     Landed cost         = FOB + allocated purchase charges per base unit (freight, customs, BIVAC... configurable
                           charge types; allocation by Value | Quantity | Weight | Volume | Manual; amounts in any
                           currency converted with the document-date rate; rounding remainder on the largest line)
     Item.FobCost        = FOB of the latest posted purchase invoice
     Item.LastCost       = LANDED cost of the latest posted purchase invoice (Inventory In does not touch it)
     Item.AverageCost    = moving weighted average, recalculated only when a posting ADDS stock:
                           new avg = (on-hand x old avg + received qty x landed cost) / (on-hand + received qty)
     Inventory value     = on-hand x average cost (views vw_InventoryValuation / ...ByWarehouse)
     Sales invoice       = COGS frozen per line at posting (average cost) + FOB / last cost snapshots, net sales,
                           gross profit and gross profit % (on net sales) in the base currency
     Sales return        = restores stock at the ORIGINAL invoice COGS (SINV -> SRET conversion procedure)
     Purchase return     = removes stock at the original invoice landed cost
     Landed Cost Adjustment (LCA) = charges arriving after receipt, allocated over the invoice lines and split:
                           still-in-stock quantity -> inventory value (average recalculated),
                           already-sold quantity   -> COGS adjustment (period P&L, inventory.CostAdjustments)
     Cancelling a posted receipt / LCA rebuilds the item costs by replaying the ledger (usp_Item_RebuildCosts)

   Objects: inventory.Items + FobCost, WeightKg, VolumeCbm; inventory.tvp_ItemReceipt re-created (+ FobCostBase);
            inventory.usp_Item_ApplyReceipts (+ @UpdateLastCost), usp_Item_RebuildCosts, usp_Item_Get / _Search /
            _SetPurchasing re-created; inventory.CostAdjustments; views vw_InventoryValuation(+ByWarehouse)
            purchase.ChargeTypes (+ usp_ChargeType_List / _Save), purchase.PurchaseCharges,
            purchase.PurchaseChargeAllocations, tvp_PurchaseCharge, tvp_ManualAllocation,
            usp_PurchaseDocument_SetCharges, usp_PurchaseCharges_Allocate;
            purchase.PurchaseDocumentLines + FobCostBase, AllocatedChargesBase; PurchaseDocuments + TotalChargesBase;
            purchase.LandedCostAdjustments / LandedCostAdjustmentLines, document type LCA,
            usp_LandedCostAdjustment_Search / _Get / _Save / _Post / _Cancel / _Delete;
            purchase.usp_PurchaseDocument_Save / _Post / _Cancel / _Delete / _Get re-created;
            sales.SalesDocumentLines + FobCostAtSale, LastCostAtSale, NetSalesBase, CogsBase, GrossProfitBase,
            GrossProfitPct, ReturnedQuantityBase; SalesDocuments + TotalGrossProfitBase;
            sales.usp_SalesDocument_Save / _Post / _Cancel / _Get re-created, usp_SalesDocument_CreateFromSource
            (SINV -> SRET), sales.usp_SalesProfit_Report; inventory.usp_StockDocument_Post re-created.
   Errors: 65012 CHARGE_ALLOCATION (purchase charges), 67xxx landed cost adjustments (67000 validation,
           67004 concurrency, 67005 not a draft, 67006 not found, 67010 invalid status, 67011 source invoice problem)
   Permissions: purchase.landedcosts.view/create/post/cancel/delete (1180-1220), purchase.chargetypes.manage
                (Configuration 910), sales.profit.view (Sales 680)
   Requires 19, 21, 22. Idempotent (types are dropped/re-created only when the new column is missing).
   ===================================================================================== */
GO

-- sqlcmd defaults to QUOTED_IDENTIFIER OFF; the procedures below insert into tables with PERSISTED
-- computed columns (Sales/Purchase document lines), which need it ON in the procedure that writes to them
-- (the setting is captured when the procedure is created).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentLines', N'U') IS NULL OR COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ShippedQuantityBase') IS NULL
BEGIN
    RAISERROR ('Run scripts 19, 21 and 22 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Items: FOB cost, weight, volume */

IF COL_LENGTH(N'inventory.Items', N'FobCost') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD
        FobCost   DECIMAL(18,6) NULL,   -- latest purchase FOB cost per base unit, base currency
        WeightKg  DECIMAL(18,3) NULL,   -- per base unit (charge allocation by weight)
        VolumeCbm DECIMAL(18,4) NULL,   -- per base unit (charge allocation by volume)
        CONSTRAINT CK_Items_WeightKg CHECK (WeightKg IS NULL OR WeightKg >= 0),
        CONSTRAINT CK_Items_VolumeCbm CHECK (VolumeCbm IS NULL OR VolumeCbm >= 0);
    PRINT 'Items: added FobCost, WeightKg, VolumeCbm';
END
GO

-- Backfill FOB from the latest posted purchase invoice when the column is new.
UPDATE i SET FobCost = x.Fob
FROM inventory.Items i
CROSS APPLY (SELECT TOP (1) Fob = l.UnitCostBase
             FROM purchase.PurchaseDocumentLines l
             INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
             INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
             WHERE dt.Code = N'PINV' AND d.Status = 2 AND l.ItemId = i.Id
             ORDER BY d.PostedAtUtc DESC, l.Id DESC) x
WHERE i.FobCost IS NULL AND x.Fob IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT           = NULL,
    @LeadTimeDays      INT           = NULL,
    @UserId            INT           = NULL,
    @PcPerContainer    INT           = NULL,
    @WeightKg          DECIMAL(18,3) = NULL,
    @VolumeCbm         DECIMAL(18,4) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @PcPerContainer IS NOT NULL AND @PcPerContainer <= 0 THROW 56000, 'PC per container must be greater than zero.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg < 0 THROW 56000, 'Weight cannot be negative.', 1;
    IF @VolumeCbm IS NOT NULL AND @VolumeCbm < 0 THROW 56000, 'Volume cannot be negative.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, PcPerContainer = @PcPerContainer,
        WeightKg = @WeightKg, VolumeCbm = @VolumeCbm, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays, i.PcPerContainer,
           i.WeightKg, i.VolumeCbm,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Search
    @Search             NVARCHAR(200) = NULL,
    @ItemFamilyId       INT           = NULL,
    @BrandId            INT           = NULL,
    @DefaultWarehouseId INT           = NULL,
    @IsActive           BIT           = NULL,
    @IsBivac            BIT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'ItemCode',
    @SortDirection      NVARCHAR(4)   = N'ASC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BrandName', N'FamilyName', N'WarehouseName', N'IsActive', N'CreatedAtUtc', N'OnHand')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           bu.SkuCode AS BaseUnitSku, ut.UnitTypeName AS BaseUnitName,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)), LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           i.DefaultSupplierId, ds.PartyName AS DefaultSupplierName,
           i.CreatedAtUtc, i.CreatedBy, i.UpdatedAtUtc, i.UpdatedBy, i.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b        ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN inventory.ItemUnits bu     ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes ut    ON ut.Id = bu.UnitTypeId
    LEFT  JOIN masterdata.Parties ds      ON ds.Id = i.DefaultSupplierId
    WHERE (@Search IS NULL
           OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u
                      WHERE u.ItemId = i.Id AND (u.SkuCode LIKE N'%' + @Search + N'%' OR u.Barcode LIKE N'%' + @Search + N'%')))
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@DefaultWarehouseId IS NULL OR i.DefaultWarehouseId = @DefaultWarehouseId)
      AND (@IsActive IS NULL OR i.IsActive = @IsActive)
      AND (@IsBivac IS NULL OR i.IsBivac = @IsBivac)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END DESC,
        i.ItemCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 2. Cost adjustments ledger + valuation views */

IF OBJECT_ID(N'inventory.CostAdjustments', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.CostAdjustments
    (
        Id             BIGINT IDENTITY(1,1) NOT NULL,
        AdjustmentDate DATETIME2(3)  NOT NULL,
        ItemId         INT           NOT NULL,
        WarehouseId    INT           NOT NULL,
        BranchId       INT           NOT NULL,
        Kind           NVARCHAR(10)  NOT NULL,     -- Inventory (value added to stock) | COGS (expense of already-sold quantity)
        AmountBase     DECIMAL(18,2) NOT NULL,     -- signed (negative = reversal)
        SourceKind     NVARCHAR(10)  NOT NULL,     -- LCA
        SourceId       INT           NOT NULL,
        SourceNumber   NVARCHAR(30)  NOT NULL,
        PurchaseLineId INT           NULL,
        CreatedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_CostAdjustments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT           NULL,
        CONSTRAINT PK_CostAdjustments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_CostAdjustments_Kind CHECK (Kind IN (N'Inventory', N'COGS')),
        CONSTRAINT FK_CostAdjustments_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_CostAdjustments_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_CostAdjustments_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id)
    );
    CREATE NONCLUSTERED INDEX IX_CostAdjustments_ItemDate ON inventory.CostAdjustments (ItemId, AdjustmentDate);
    CREATE NONCLUSTERED INDEX IX_CostAdjustments_Source   ON inventory.CostAdjustments (SourceKind, SourceId);
    PRINT 'Created inventory.CostAdjustments';
END
GO

CREATE OR ALTER VIEW inventory.vw_InventoryValuation
AS
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId,
           OnHandBase = inventory.fn_StockOnHand(i.Id, NULL),
           i.AverageCost, i.LastCost, i.FobCost,
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2))
    FROM inventory.Items i
    WHERE i.IsActive = 1;
GO

CREATE OR ALTER VIEW inventory.vw_InventoryValuationByWarehouse
AS
    SELECT b.ItemId, b.ItemCode, b.ItemName, b.WarehouseId, b.WarehouseCode, b.WarehouseName, b.BranchId,
           b.OnHandBase, i.AverageCost,
           InventoryValue = CAST(b.OnHandBase * i.AverageCost AS DECIMAL(18,2))
    FROM inventory.vw_StockBalance b
    INNER JOIN inventory.Items i ON i.Id = b.ItemId;
GO

/* ================================================================== 3. Receipts: moving average + FOB (type re-created) */

-- Before usp_Item_RebuildCosts below reads l.FobCostBase: a procedure may name a missing table but not a
-- missing column, so on an empty database the CREATE failed when this ran in section 5.
IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'FobCostBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocumentLines ADD
        FobCostBase          DECIMAL(18,6) NULL,                                                       -- per base unit, base currency
        AllocatedChargesBase DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Charges DEFAULT (0);   -- landed charges of the line
    PRINT 'PurchaseDocumentLines: added FobCostBase, AllocatedChargesBase';
END
GO

IF TYPE_ID(N'inventory.tvp_ItemReceipt') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns c INNER JOIN sys.table_types tt ON tt.type_table_object_id = c.object_id
                   WHERE tt.name = N'tvp_ItemReceipt' AND SCHEMA_NAME(tt.schema_id) = N'inventory' AND c.name = N'FobCostBase')
BEGIN
    IF OBJECT_ID(N'inventory.usp_Item_ApplyReceipts', N'P') IS NOT NULL DROP PROCEDURE inventory.usp_Item_ApplyReceipts;
    IF OBJECT_ID(N'inventory.usp_StockDocument_Post', N'P') IS NOT NULL DROP PROCEDURE inventory.usp_StockDocument_Post;
    IF OBJECT_ID(N'sales.usp_SalesDocument_Post', N'P') IS NOT NULL DROP PROCEDURE sales.usp_SalesDocument_Post;
    IF OBJECT_ID(N'purchase.usp_PurchaseDocument_Post', N'P') IS NOT NULL DROP PROCEDURE purchase.usp_PurchaseDocument_Post;
    DROP TYPE inventory.tvp_ItemReceipt;
    PRINT 'Dropped inventory.tvp_ItemReceipt (re-created with FobCostBase; the posting procedures are re-created below)';
END
GO

IF TYPE_ID(N'inventory.tvp_ItemReceipt') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ItemReceipt AS TABLE
    (
        ItemId       INT           NOT NULL,
        QuantityBase INT           NOT NULL,      -- received, base units (> 0)
        UnitCostBase DECIMAL(18,6) NOT NULL,      -- LANDED cost per base unit, base currency
        FobCostBase  DECIMAL(18,6) NULL           -- FOB per base unit (purchases only)
    );
    PRINT 'Created type inventory.tvp_ItemReceipt';
END
GO

-- Moving average. CALL BEFORE the receipt movements are inserted. @UpdateLastCost = 1 only for purchase receipts.
CREATE OR ALTER PROCEDURE inventory.usp_Item_ApplyReceipts
    @Receipts       inventory.tvp_ItemReceipt READONLY,
    @SupplierId     INT = NULL,
    @UserId         INT = NULL,
    @UpdateLastCost BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT ItemId,
               Qty    = SUM(QuantityBase),
               Cost   = SUM(CAST(QuantityBase AS DECIMAL(18,6)) * UnitCostBase),
               FobQty = SUM(CASE WHEN FobCostBase IS NOT NULL THEN QuantityBase ELSE 0 END),
               Fob    = SUM(CASE WHEN FobCostBase IS NOT NULL THEN CAST(QuantityBase AS DECIMAL(18,6)) * FobCostBase ELSE 0 END)
        FROM @Receipts WHERE QuantityBase > 0 GROUP BY ItemId
    )
    UPDATE i
    SET AverageCost       = CASE WHEN oh.Q + a.Qty > 0 THEN (oh.Q * i.AverageCost + a.Cost) / (oh.Q + a.Qty) ELSE i.AverageCost END,
        LastCost          = CASE WHEN @UpdateLastCost = 1 THEN a.Cost / a.Qty ELSE i.LastCost END,
        FobCost           = CASE WHEN @UpdateLastCost = 1 AND a.FobQty > 0 THEN a.Fob / a.FobQty ELSE i.FobCost END,
        LastSupplierId    = CASE WHEN @UpdateLastCost = 1 THEN COALESCE(@SupplierId, i.LastSupplierId) ELSE i.LastSupplierId END,
        LastPurchaseAtUtc = CASE WHEN @UpdateLastCost = 1 AND @SupplierId IS NOT NULL THEN SYSUTCDATETIME() ELSE i.LastPurchaseAtUtc END
    FROM inventory.Items i
    INNER JOIN agg a ON a.ItemId = i.Id
    CROSS APPLY (SELECT Q = CAST(CASE WHEN inventory.fn_StockOnHand(i.Id, NULL) > 0 THEN inventory.fn_StockOnHand(i.Id, NULL) ELSE 0 END AS DECIMAL(18,6))) oh;
END
GO

-- Replays the ledger (documents without reversal) + inventory cost adjustments in date order -> exact moving average;
-- LastCost / FobCost from the latest posted purchase invoice. @ItemId NULL = every item (maintenance).
CREATE OR ALTER PROCEDURE inventory.usp_Item_RebuildCosts
    @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Events TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT, Qty INT, Cost DECIMAL(18,6), Amount DECIMAL(18,2));
    INSERT INTO @Events (ItemId, Qty, Cost, Amount)
    SELECT x.ItemId, x.Qty, x.Cost, x.Amount
    FROM
    (
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase, Cost = m.UnitCostBase, Amount = CAST(NULL AS DECIMAL(18,2))
        FROM inventory.StockMovements m
        WHERE (@ItemId IS NULL OR m.ItemId = @ItemId)
          AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentId = m.DocumentId AND r.IsReversal = 1)
        UNION ALL
        SELECT c.ItemId, c.AdjustmentDate, 2, CAST(c.Id AS INT), 0, NULL, c.AmountBase
        FROM inventory.CostAdjustments c
        WHERE c.Kind = N'Inventory' AND (@ItemId IS NULL OR c.ItemId = @ItemId)
    ) x
    ORDER BY x.ItemId, x.EventDate, x.Src, x.SrcId;

    DECLARE @Result TABLE (ItemId INT PRIMARY KEY, AverageCost DECIMAL(18,6));
    DECLARE @CurItem INT = NULL, @OnHand DECIMAL(18,6) = 0, @Avg DECIMAL(18,6) = 0;
    DECLARE @EItem INT, @EQty INT, @ECost DECIMAL(18,6), @EAmount DECIMAL(18,2);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId, Qty, Cost, Amount FROM @Events ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @CurItem IS NULL OR @CurItem <> @EItem
        BEGIN
            IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);
            SELECT @CurItem = @EItem, @OnHand = 0, @Avg = 0;
        END

        IF @EAmount IS NOT NULL                                   -- inventory value adjustment (LCA)
            SET @Avg = CASE WHEN @OnHand > 0 THEN @Avg + @EAmount / @OnHand ELSE @Avg END;
        ELSE IF @EQty > 0                                         -- receipt
        BEGIN
            SET @Avg = CASE WHEN @OnHand + @EQty > 0 THEN ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) * @Avg + @EQty * ISNULL(@ECost, @Avg)) / ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) + @EQty) ELSE @Avg END;
            SET @OnHand = @OnHand + @EQty;
        END
        ELSE                                                      -- issue: average unchanged
            SET @OnHand = @OnHand + @EQty;

        FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    END
    CLOSE cur; DEALLOCATE cur;
    IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);

    -- Items with no remaining events (everything cancelled) fall back to 0.
    UPDATE i SET AverageCost = ISNULL(r.AverageCost, 0)
    FROM inventory.Items i
    LEFT JOIN @Result r ON r.ItemId = i.Id
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);

    UPDATE i
    SET LastCost = x.Landed, FobCost = x.Fob, LastSupplierId = x.SupplierId, LastPurchaseAtUtc = x.PostedAtUtc
    FROM inventory.Items i
    OUTER APPLY (SELECT TOP (1) Landed = l.UnitCostBase, Fob = l.FobCostBase, d.SupplierId, d.PostedAtUtc
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                 INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                 WHERE dt.Code = N'PINV' AND d.Status = 2 AND l.ItemId = i.Id
                 ORDER BY d.PostedAtUtc DESC, l.Id DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END
GO

/* ================================================================== 4. Purchase charge types (US-MD-008) */

IF OBJECT_ID(N'purchase.ChargeTypes', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.ChargeTypes
    (
        Id                  INT IDENTITY(1,1) NOT NULL,
        ChargeCode          NVARCHAR(10)  NOT NULL,
        ChargeName          NVARCHAR(100) NOT NULL,
        AllocationMethod    NVARCHAR(10)  NOT NULL,     -- Value | Quantity | Weight | Volume | Manual
        IncludeInLandedCost BIT           NOT NULL CONSTRAINT DF_ChargeTypes_Landed DEFAULT (1),
        IsRecoverableTax    BIT           NOT NULL CONSTRAINT DF_ChargeTypes_RecoverableTax DEFAULT (0),   -- recoverable VAT: never part of the item cost
        Description         NVARCHAR(500) NULL,
        IsActive            BIT           NOT NULL CONSTRAINT DF_ChargeTypes_IsActive DEFAULT (1),
        CreatedAtUtc        DATETIME2(3)  NOT NULL CONSTRAINT DF_ChargeTypes_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy           INT           NULL,
        UpdatedAtUtc        DATETIME2(3)  NULL,
        UpdatedBy           INT           NULL,
        RowVersion          ROWVERSION    NOT NULL,
        CONSTRAINT PK_ChargeTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ChargeTypes_Code UNIQUE (ChargeCode),
        CONSTRAINT UQ_ChargeTypes_Name UNIQUE (ChargeName),
        CONSTRAINT CK_ChargeTypes_Method CHECK (AllocationMethod IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')),
        CONSTRAINT CK_ChargeTypes_TaxNotLanded CHECK (NOT (IsRecoverableTax = 1 AND IncludeInLandedCost = 1)),
        CONSTRAINT FK_ChargeTypes_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_ChargeTypes_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created purchase.ChargeTypes';
END
GO

MERGE purchase.ChargeTypes AS t
USING (VALUES
    (N'FRE', N'Freight',               N'Weight',   1, 0, N'Ocean / air freight charges'),
    (N'INS', N'Insurance',             N'Value',    1, 0, N'Cargo insurance'),
    (N'CUS', N'Customs',               N'Value',    1, 0, N'Customs duty and taxes'),
    (N'CLR', N'Clearing',              N'Value',    1, 0, N'Clearing agent fees'),
    (N'POR', N'Port Charges',          N'Volume',   1, 0, N'Port handling charges'),
    (N'BIV', N'BIVAC / Inspection',    N'Value',    1, 0, N'BIVAC inspection fees'),
    (N'TRP', N'Inland Transportation', N'Weight',   1, 0, N'Local transport to warehouse'),
    (N'HDL', N'Handling',              N'Quantity', 1, 0, N'Loading / unloading charges'),
    (N'ADM', N'Administration',        N'Manual',   0, 1, N'Administrative fees (not in cost)'),
    (N'OTH', N'Other Charges',         N'Manual',   1, 0, N'Other acquisition costs')
) AS s (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description)
ON t.ChargeCode = s.ChargeCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description)
    VALUES (s.ChargeCode, s.ChargeName, s.AllocationMethod, s.IncludeInLandedCost, s.IsRecoverableTax, s.Description);
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Search
    @Search              NVARCHAR(100) = NULL,   -- code or name (contains)
    @AllocationMethod    NVARCHAR(10)  = NULL,
    @IncludeInLandedCost BIT           = NULL,   -- "Cost impact" filter
    @IsActive            BIT           = NULL,
    @SortColumn          NVARCHAR(30)  = N'ChargeCode',
    @SortDirection       NVARCHAR(4)   = N'ASC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeCode', N'ChargeName', N'AllocationMethod', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'ChargeCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ChargeCode, c.ChargeName, c.AllocationMethod, c.IncludeInLandedCost, c.IsRecoverableTax, c.Description, c.IsActive,
           UsageCount = (SELECT COUNT(*) FROM purchase.PurchaseCharges pc WHERE pc.ChargeTypeId = c.Id),
           c.CreatedAtUtc, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.ChargeTypes c
    WHERE (@Search IS NULL OR c.ChargeCode LIKE N'%' + @Search + N'%' OR c.ChargeName LIKE N'%' + @Search + N'%')
      AND (@AllocationMethod IS NULL OR c.AllocationMethod = @AllocationMethod)
      AND (@IncludeInLandedCost IS NULL OR c.IncludeInLandedCost = @IncludeInLandedCost)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.ChargeCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Lookup
    @ActiveOnly BIT = 1, @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, IsActive
    FROM purchase.ChargeTypes
    WHERE @ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId
    ORDER BY ChargeName;
END
GO

-- Create (@Id NULL) or update. Errors 68xxx: 68000 validation, 68001 duplicate code, 68002 duplicate name, 68004 concurrency, 68005 in use, 68006 not found.
CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Save
    @Id                  INT           = NULL,
    @ChargeCode          NVARCHAR(10),
    @ChargeName          NVARCHAR(100),
    @AllocationMethod    NVARCHAR(10),
    @IncludeInLandedCost BIT           = 1,
    @IsRecoverableTax    BIT           = 0,
    @Description         NVARCHAR(500) = NULL,
    @IsActive            BIT           = 1,
    @RowVersion          BINARY(8)     = NULL,
    @UserId              INT           = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ChargeCode = UPPER(NULLIF(LTRIM(RTRIM(@ChargeCode)), N''));
    SET @ChargeName = NULLIF(LTRIM(RTRIM(@ChargeName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @ChargeCode IS NULL THROW 68000, 'Charge Code is required.', 1;
    IF @ChargeName IS NULL THROW 68000, 'Charge Name is required.', 1;
    IF @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THROW 68000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF ISNULL(@IsRecoverableTax, 0) = 1 AND ISNULL(@IncludeInLandedCost, 1) = 1 THROW 68000, 'A recoverable tax cannot be included in the landed cost.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeCode = @ChargeCode AND (@Id IS NULL OR Id <> @Id)) THROW 68001, 'This Charge Code already exists.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeName = @ChargeName AND (@Id IS NULL OR Id <> @Id)) THROW 68002, 'This Charge Name already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO purchase.ChargeTypes (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description, IsActive, CreatedBy)
        VALUES (@ChargeCode, @ChargeName, @AllocationMethod, ISNULL(@IncludeInLandedCost, 1), ISNULL(@IsRecoverableTax, 0), @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 68004, 'This charge type was modified by another user. Reload the page and try again.', 1;
        UPDATE purchase.ChargeTypes
        SET ChargeCode = @ChargeCode, ChargeName = @ChargeName, AllocationMethod = @AllocationMethod, IncludeInLandedCost = ISNULL(@IncludeInLandedCost, 1),
            IsRecoverableTax = ISNULL(@IsRecoverableTax, 0), Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 68004, 'This charge type was modified by another user. Reload the page and try again.', 1;
    UPDATE purchase.ChargeTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
    IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE ChargeTypeId = @Id)
        THROW 68005, 'This charge type was used in transactions and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM purchase.ChargeTypes WHERE Id = @Id;
END
GO

/* ================================================================== 5. Purchase charges on invoices / adjustments + allocations */

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'TotalChargesBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        TotalChargesBase    DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseDocuments_Charges DEFAULT (0),      -- landed charges (invoice + adjustments)
        TotalLandedCostBase DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseDocuments_Landed DEFAULT (0);       -- TotalAmountBase + TotalChargesBase
    PRINT 'PurchaseDocuments: added TotalChargesBase, TotalLandedCostBase';
END
GO

-- Existing posted invoices: FOB = the landed cost known so far (no charges existed).
UPDATE l SET FobCostBase = l.UnitCostBase
FROM purchase.PurchaseDocumentLines l
INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
WHERE l.FobCostBase IS NULL AND d.Status IN (2, 3, 4) AND l.UnitCostBase IS NOT NULL;
UPDATE purchase.PurchaseDocuments SET TotalLandedCostBase = TotalAmountBase WHERE TotalLandedCostBase = 0 AND TotalAmountBase <> 0;
GO

IF OBJECT_ID(N'purchase.PurchaseCharges', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseCharges
    (
        Id                        INT IDENTITY(1,1) NOT NULL,
        DocumentKind              NVARCHAR(10)  NOT NULL,     -- PINV (charges known on the invoice) | LCA (landed cost adjustment)
        DocumentId                INT           NOT NULL,
        LineNumber                INT           NOT NULL,
        ChargeTypeId              INT           NOT NULL,
        Description               NVARCHAR(200) NULL,
        ProviderPartyId           INT           NULL,         -- who bills the charge (forwarder, customs agent...)
        Reference                 NVARCHAR(100) NULL,         -- provider's invoice / receipt number
        CurrencyId                INT           NOT NULL,
        RateType                  TINYINT       NOT NULL CONSTRAINT DF_PurchaseCharges_RateType DEFAULT (1),
        ExchangeRate              DECIMAL(18,6) NOT NULL CONSTRAINT DF_PurchaseCharges_Rate DEFAULT (1),
        Amount                    DECIMAL(18,2) NOT NULL,
        AmountBase                DECIMAL(18,2) NOT NULL,
        AllocationMethod          NVARCHAR(10)  NOT NULL,     -- copied from the type, overridable per charge
        IncludeInLandedCost       BIT           NOT NULL,     -- copied from the type at save time
        IncludedInSupplierInvoice BIT           NOT NULL CONSTRAINT DF_PurchaseCharges_InSupplierInvoice DEFAULT (0),
        Notes                     NVARCHAR(300) NULL,
        CreatedAtUtc              DATETIME2(3)  NOT NULL CONSTRAINT DF_PurchaseCharges_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy                 INT           NULL,
        CONSTRAINT PK_PurchaseCharges PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseCharges_Line UNIQUE (DocumentKind, DocumentId, LineNumber),
        CONSTRAINT CK_PurchaseCharges_Kind CHECK (DocumentKind IN (N'PINV', N'LCA')),
        CONSTRAINT CK_PurchaseCharges_Method CHECK (AllocationMethod IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')),
        CONSTRAINT CK_PurchaseCharges_Amount CHECK (Amount >= 0),
        CONSTRAINT FK_PurchaseCharges_Type     FOREIGN KEY (ChargeTypeId)    REFERENCES purchase.ChargeTypes (Id),
        CONSTRAINT FK_PurchaseCharges_Provider FOREIGN KEY (ProviderPartyId) REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_PurchaseCharges_Currency FOREIGN KEY (CurrencyId)      REFERENCES masterdata.Currencies (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseCharges_Document ON purchase.PurchaseCharges (DocumentKind, DocumentId);
    PRINT 'Created purchase.PurchaseCharges';
END
GO

IF OBJECT_ID(N'purchase.PurchaseChargeAllocations', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseChargeAllocations
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        ChargeId       INT           NOT NULL,
        PurchaseLineId INT           NOT NULL,     -- line of the PURCHASE INVOICE that receives the cost
        Basis          DECIMAL(18,6) NULL,         -- the share basis used (value, quantity, kg, cbm) - NULL for manual
        AmountBase     DECIMAL(18,2) NOT NULL,
        IsManual       BIT           NOT NULL CONSTRAINT DF_PurchaseChargeAllocations_Manual DEFAULT (0),
        CONSTRAINT PK_PurchaseChargeAllocations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseChargeAllocations UNIQUE (ChargeId, PurchaseLineId),
        CONSTRAINT FK_PurchaseChargeAllocations_Charge FOREIGN KEY (ChargeId)       REFERENCES purchase.PurchaseCharges (Id),
        CONSTRAINT FK_PurchaseChargeAllocations_Line   FOREIGN KEY (PurchaseLineId) REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseChargeAllocations_Line ON purchase.PurchaseChargeAllocations (PurchaseLineId);
    PRINT 'Created purchase.PurchaseChargeAllocations';
END
GO

IF TYPE_ID(N'purchase.tvp_PurchaseCharge') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PurchaseCharge AS TABLE
    (
        LineNumber                INT           NOT NULL PRIMARY KEY,
        ChargeTypeId              INT           NOT NULL,
        Description               NVARCHAR(200) NULL,
        ProviderPartyId           INT           NULL,
        Reference                 NVARCHAR(100) NULL,
        CurrencyId                INT           NULL,        -- NULL = document currency (invoice) / base currency (adjustment)
        RateType                  TINYINT       NULL,        -- NULL = 1 Official
        ExchangeRate              DECIMAL(18,6) NULL,        -- NULL = rate of the document date
        Amount                    DECIMAL(18,2) NOT NULL,
        AllocationMethod          NVARCHAR(10)  NULL,        -- NULL = the type's default
        IncludedInSupplierInvoice BIT           NULL,
        Notes                     NVARCHAR(300) NULL
    );
    PRINT 'Created type purchase.tvp_PurchaseCharge';
END
GO

IF TYPE_ID(N'purchase.tvp_ManualAllocation') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_ManualAllocation AS TABLE
    (
        ChargeLineNumber INT           NOT NULL,
        PurchaseLineId   INT           NOT NULL,
        AmountBase       DECIMAL(18,2) NOT NULL,
        PRIMARY KEY (ChargeLineNumber, PurchaseLineId)
    );
    PRINT 'Created type purchase.tvp_ManualAllocation';
END
GO

-- Shared writer: replaces the charges of a document (PINV draft or LCA draft) and stores manual allocations.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseCharges_Write
    @DocumentKind      NVARCHAR(10),
    @DocumentId        INT,
    @DocumentDate      DATE,
    @DefaultCurrencyId INT,
    @TargetInvoiceId   INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Charge ' + CAST(c.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN ct.Id IS NULL THEN N'charge type not found.'
             WHEN ct.IsActive = 0 THEN N'charge type ' + ct.ChargeName + N' is inactive.'
             WHEN c.Amount < 0 THEN N'amount cannot be negative.'
             WHEN c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THEN N'unknown allocation method.'
             WHEN c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1) THEN N'currency not found or inactive.'
             WHEN c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1) THEN N'provider not found or inactive.' END
    FROM @Charges c
    LEFT JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    WHERE ct.Id IS NULL OR ct.IsActive = 0 OR c.Amount < 0
       OR (c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual'))
       OR (c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0)
       OR (c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1))
       OR (c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1))
    ORDER BY c.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    -- Resolve currency + rate per charge (base currency -> 1).
    DECLARE @Resolved TABLE (LineNumber INT PRIMARY KEY, CurrencyId INT, RateType TINYINT, Rate DECIMAL(18,6), AmountBase DECIMAL(18,2), Method NVARCHAR(10), InLanded BIT);
    INSERT INTO @Resolved (LineNumber, CurrencyId, RateType, Rate, AmountBase, Method, InLanded)
    SELECT c.LineNumber, cur.Id, ISNULL(c.RateType, 1),
           r.Rate,
           ROUND(c.Amount / NULLIF(r.Rate, 0), 2),
           ISNULL(c.AllocationMethod, ct.AllocationMethod),
           ct.IncludeInLandedCost
    FROM @Charges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    CROSS APPLY (SELECT Id, IsBaseCurrency FROM masterdata.Currencies WHERE Id = ISNULL(c.CurrencyId, @DefaultCurrencyId)) cur
    CROSS APPLY (SELECT Rate = CASE WHEN cur.IsBaseCurrency = 1 THEN 1 ELSE COALESCE(c.ExchangeRate, masterdata.fn_GetRate(cur.Id, ISNULL(c.RateType, 1), @DocumentDate)) END) r;

    SELECT TOP (1) @Msg = N'Charge ' + CAST(LineNumber AS NVARCHAR(10)) + N': no exchange rate for its currency on ' + CONVERT(NVARCHAR(10), @DocumentDate, 120) + N' - add one or enter the rate.'
    FROM @Resolved WHERE Rate IS NULL ORDER BY LineNumber;
    IF @Msg IS NOT NULL THROW 65008, @Msg, 1;

    -- Manual allocations must match a Manual charge, reference lines of the target invoice and sum to the charge amount.
    IF EXISTS (SELECT 1 FROM @ManualAllocations m LEFT JOIN @Resolved r ON r.LineNumber = m.ChargeLineNumber WHERE r.LineNumber IS NULL OR r.Method <> N'Manual')
        THROW 65012, 'A manual allocation refers to a charge that does not exist or is not allocated manually.', 1;
    IF EXISTS (SELECT 1 FROM @ManualAllocations m WHERE NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l WHERE l.Id = m.PurchaseLineId AND l.DocumentId = @TargetInvoiceId))
        THROW 65012, 'A manual allocation refers to a line that does not belong to the invoice.', 1;
    IF EXISTS (SELECT 1 FROM @ManualAllocations WHERE AmountBase < 0) THROW 65012, 'Manual allocation amounts cannot be negative.', 1;
    SELECT TOP (1) @Msg = N'Charge ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': manual allocations (' + CAST(ISNULL(m.Total, 0) AS NVARCHAR(30)) + N') must equal the charge amount in base currency (' + CAST(r.AmountBase AS NVARCHAR(30)) + N').'
    FROM @Resolved r
    LEFT JOIN (SELECT ChargeLineNumber, Total = SUM(AmountBase) FROM @ManualAllocations GROUP BY ChargeLineNumber) m ON m.ChargeLineNumber = r.LineNumber
    WHERE r.Method = N'Manual' AND r.InLanded = 1 AND r.AmountBase > 0 AND ABS(ISNULL(m.Total, 0) - r.AmountBase) > 0.01
    ORDER BY r.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = @DocumentKind AND c.DocumentId = @DocumentId;
    DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId;

    INSERT INTO purchase.PurchaseCharges (DocumentKind, DocumentId, LineNumber, ChargeTypeId, Description, ProviderPartyId, Reference, CurrencyId, RateType, ExchangeRate,
                                          Amount, AmountBase, AllocationMethod, IncludeInLandedCost, IncludedInSupplierInvoice, Notes, CreatedBy)
    SELECT @DocumentKind, @DocumentId, c.LineNumber, c.ChargeTypeId, NULLIF(LTRIM(RTRIM(c.Description)), N''), c.ProviderPartyId, NULLIF(LTRIM(RTRIM(c.Reference)), N''),
           r.CurrencyId, r.RateType, r.Rate, c.Amount, r.AmountBase, r.Method, r.InLanded, ISNULL(c.IncludedInSupplierInvoice, 0), NULLIF(LTRIM(RTRIM(c.Notes)), N''), @UserId
    FROM @Charges c INNER JOIN @Resolved r ON r.LineNumber = c.LineNumber;

    INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
    SELECT pc.Id, m.PurchaseLineId, NULL, m.AmountBase, 1
    FROM @ManualAllocations m
    INNER JOIN purchase.PurchaseCharges pc ON pc.DocumentKind = @DocumentKind AND pc.DocumentId = @DocumentId AND pc.LineNumber = m.ChargeLineNumber
    WHERE pc.IncludeInLandedCost = 1;
END
GO

-- Charges of a DRAFT purchase invoice (allocation happens at posting).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_SetCharges
    @DocumentId        INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8) = NULL,
    @UserId            INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Date DATE, @CurrencyId INT;
    SELECT @Status = d.Status, @TypeCode = dt.Code, @Date = d.DocumentDate, @CurrencyId = d.CurrencyId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PINV' THROW 65010, 'Charges are entered on purchase invoices only (use a Landed Cost Adjustment after posting).', 1;
    IF @Status <> 1 THROW 65005, 'Charges can only be changed on a draft invoice.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_PurchaseCharges_Write N'PINV', @DocumentId, @Date, @CurrencyId, @DocumentId, @Charges, @ManualAllocations, @UserId;
        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @DocumentId;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@DocumentId, N'Updated', N'Charges saved: ' + CAST((SELECT COUNT(*) FROM @Charges) AS NVARCHAR(10)) + N' line(s)', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Allocates every landed, non-manual charge of (kind, document) over the lines of the target invoice.
-- Basis: Value = line total in base currency, Quantity = base units, Weight = base units x item WeightKg, Volume = base units x item VolumeCbm.
-- Rounded to 2 decimals; the rounding remainder goes to the line with the largest basis, so the sum equals the charge.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseCharges_Allocate
    @DocumentKind    NVARCHAR(10),
    @DocumentId      INT,
    @TargetInvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @TargetInvoiceId);

    DECLARE @Lines TABLE (LineId INT PRIMARY KEY, LineNumber INT, ItemCode NVARCHAR(30), ValueBase DECIMAL(18,6), QtyBase INT, WeightKg DECIMAL(18,3), VolumeCbm DECIMAL(18,4));
    INSERT INTO @Lines (LineId, LineNumber, ItemCode, ValueBase, QtyBase, WeightKg, VolumeCbm)
    SELECT l.Id, l.LineNumber, i.ItemCode, l.LineTotal / @Rate, l.QuantityBase, i.WeightKg, i.VolumeCbm
    FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.DocumentId = @TargetInvoiceId;

    DECLARE @ChargeId INT, @LineNo INT, @Method NVARCHAR(10), @Amount DECIMAL(18,2), @Msg NVARCHAR(400);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT Id, LineNumber, AllocationMethod, AmountBase FROM purchase.PurchaseCharges
        WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId AND IncludeInLandedCost = 1 AND AllocationMethod <> N'Manual'
        ORDER BY LineNumber;
    OPEN cur;
    FETCH NEXT FROM cur INTO @ChargeId, @LineNo, @Method, @Amount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM purchase.PurchaseChargeAllocations WHERE ChargeId = @ChargeId AND IsManual = 0;

        IF @Method = N'Weight' AND EXISTS (SELECT 1 FROM @Lines WHERE WeightKg IS NULL)
        BEGIN
            SELECT TOP (1) @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': item ' + ItemCode + N' has no weight (kg) - set it in Item Definition or change the allocation method.' FROM @Lines WHERE WeightKg IS NULL ORDER BY LineNumber;
            THROW 65012, @Msg, 1;
        END
        IF @Method = N'Volume' AND EXISTS (SELECT 1 FROM @Lines WHERE VolumeCbm IS NULL)
        BEGIN
            SELECT TOP (1) @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': item ' + ItemCode + N' has no volume (CBM) - set it in Item Definition or change the allocation method.' FROM @Lines WHERE VolumeCbm IS NULL ORDER BY LineNumber;
            THROW 65012, @Msg, 1;
        END

        DECLARE @Basis TABLE (LineId INT PRIMARY KEY, Basis DECIMAL(18,6));
        DELETE FROM @Basis;
        INSERT INTO @Basis (LineId, Basis)
        SELECT LineId, CASE @Method WHEN N'Value' THEN ValueBase WHEN N'Quantity' THEN QtyBase WHEN N'Weight' THEN QtyBase * WeightKg WHEN N'Volume' THEN QtyBase * VolumeCbm END
        FROM @Lines;

        DECLARE @Total DECIMAL(18,6) = (SELECT SUM(Basis) FROM @Basis);
        IF @Total IS NULL OR @Total <= 0
        BEGIN
            SET @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': the allocation basis (' + @Method + N') is zero for every line - use another method or a manual allocation.';
            THROW 65012, @Msg, 1;
        END

        INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
        SELECT @ChargeId, LineId, Basis, ROUND(@Amount * Basis / @Total, 2), 0 FROM @Basis;

        DECLARE @Remainder DECIMAL(18,2) = @Amount - (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations WHERE ChargeId = @ChargeId);
        IF @Remainder <> 0
            UPDATE a SET AmountBase = a.AmountBase + @Remainder
            FROM purchase.PurchaseChargeAllocations a
            WHERE a.Id = (SELECT TOP (1) a2.Id FROM purchase.PurchaseChargeAllocations a2 INNER JOIN @Basis b ON b.LineId = a2.PurchaseLineId
                          WHERE a2.ChargeId = @ChargeId ORDER BY b.Basis DESC, a2.PurchaseLineId);

        FETCH NEXT FROM cur INTO @ChargeId, @LineNo, @Method, @Amount;
    END
    CLOSE cur; DEALLOCATE cur;
END
GO

/* ================================================================== 6. Purchase documents re-created (FOB / landed / charges) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @SupplierId         INT,
    @CurrencyId         INT            = NULL,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @SupplierReference  NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @SourceDocumentId   INT            = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            -- Lines are replaced: manual charge allocations pointing at the old lines are dropped (the charges stay).
            DELETE a FROM purchase.PurchaseChargeAllocations a
            INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId
            WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, FobCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, @WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.UnitCostBase END,      -- returns carry the invoice LANDED cost
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.FobCostBase END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N' (order confirmed)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId, @Number = d.DocumentNumber
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @Id AND Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: posted landed cost adjustments refer to it. Cancel those first.', 1;

        DECLARE @Msg NVARCHAR(400);
        IF @Direction = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason = N'Fully received')
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled receipt / return changes the cost history: replay the ledger for the items concerned.
        IF @Direction <> 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 1 THROW 65005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Landed Cost Adjustments (charges arriving after receipt) */

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'LCA', N'Landed Cost Adjustment', N'Purchase', 0, N'LCA-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
UPDATE inventory.DocumentTypes SET DefaultPricing = N'None', PriceEditable = 0 WHERE Code = N'LCA';
GO

IF OBJECT_ID(N'purchase.LandedCostAdjustments', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.LandedCostAdjustments
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId       INT            NOT NULL,
        DocumentNumber       NVARCHAR(30)   NOT NULL,
        DocumentDate         DATE           NOT NULL,
        BranchId             INT            NOT NULL,
        SourceInvoiceId      INT            NOT NULL,     -- posted purchase invoice
        Notes                NVARCHAR(1000) NULL,
        Status               TINYINT        NOT NULL CONSTRAINT DF_LandedCostAdjustments_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled
        TotalChargesBase     DECIMAL(18,2)  NOT NULL CONSTRAINT DF_LandedCostAdjustments_Total DEFAULT (0),      -- landed charges only
        InventoryPortionBase DECIMAL(18,2)  NOT NULL CONSTRAINT DF_LandedCostAdjustments_Inv DEFAULT (0),
        CogsPortionBase      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_LandedCostAdjustments_Cogs DEFAULT (0),
        PostedAtUtc          DATETIME2(3)   NULL,
        PostedBy             INT            NULL,
        CancelledAtUtc       DATETIME2(3)   NULL,
        CancelledBy          INT            NULL,
        CancelReason         NVARCHAR(300)  NULL,
        CreatedAtUtc         DATETIME2(3)   NOT NULL CONSTRAINT DF_LandedCostAdjustments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy            INT            NULL,
        UpdatedAtUtc         DATETIME2(3)   NULL,
        UpdatedBy            INT            NULL,
        RowVersion           ROWVERSION     NOT NULL,
        CONSTRAINT PK_LandedCostAdjustments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_LandedCostAdjustments_Number UNIQUE (DocumentNumber),
        CONSTRAINT CK_LandedCostAdjustments_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT FK_LandedCostAdjustments_Type      FOREIGN KEY (DocumentTypeId)  REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_LandedCostAdjustments_Branch    FOREIGN KEY (BranchId)        REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_LandedCostAdjustments_Invoice   FOREIGN KEY (SourceInvoiceId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_LandedCostAdjustments_PostedBy  FOREIGN KEY (PostedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_LandedCostAdjustments_CreatedBy FOREIGN KEY (CreatedBy)       REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_LandedCostAdjustments_Invoice ON purchase.LandedCostAdjustments (SourceInvoiceId, Status);
    PRINT 'Created purchase.LandedCostAdjustments';
END
GO

IF OBJECT_ID(N'purchase.LandedCostAdjustmentLines', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.LandedCostAdjustmentLines
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        AdjustmentId         INT           NOT NULL,
        PurchaseLineId       INT           NOT NULL,
        ItemId               INT           NOT NULL,
        WarehouseId          INT           NOT NULL,
        ReceivedBase         INT           NOT NULL,     -- invoice line quantity (base units)
        NetReceivedBase      INT           NOT NULL,     -- received - returned
        RemainingBase        INT           NOT NULL,     -- still in stock (approximation, see header)
        AllocatedBase        DECIMAL(18,2) NOT NULL,     -- charges allocated to the line
        ExtraPerBaseUnit     DECIMAL(18,6) NOT NULL,     -- AllocatedBase / ReceivedBase
        InventoryPortionBase DECIMAL(18,2) NOT NULL,
        CogsPortionBase      DECIMAL(18,2) NOT NULL,
        LandedCostBefore     DECIMAL(18,6) NOT NULL,
        LandedCostAfter      DECIMAL(18,6) NOT NULL,
        CONSTRAINT PK_LandedCostAdjustmentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_LandedCostAdjustmentLines UNIQUE (AdjustmentId, PurchaseLineId),
        CONSTRAINT FK_LandedCostAdjustmentLines_Adj  FOREIGN KEY (AdjustmentId)   REFERENCES purchase.LandedCostAdjustments (Id),
        CONSTRAINT FK_LandedCostAdjustmentLines_Line FOREIGN KEY (PurchaseLineId) REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    PRINT 'Created purchase.LandedCostAdjustmentLines';
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Search
    @Search          NVARCHAR(100) = NULL,   -- number, invoice number, supplier
    @SourceInvoiceId INT          = NULL,
    @BranchId        INT          = NULL,
    @Status          TINYINT      = NULL,
    @DateFrom        DATE         = NULL,
    @DateTo          DATE         = NULL,
    @PageNumber      INT          = 1,
    @PageSize        INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT a.Id, a.DocumentNumber, a.DocumentDate, a.BranchId, b.BranchName, a.SourceInvoiceId, inv.DocumentNumber AS SourceInvoiceNumber,
           inv.SupplierId, sp.PartyName AS SupplierName, a.Status, a.TotalChargesBase, a.InventoryPortionBase, a.CogsPortionBase,
           a.PostedAtUtc, pu.FullName AS PostedByName, a.CreatedAtUtc, cu.FullName AS CreatedByName, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.LandedCostAdjustments a
    INNER JOIN masterdata.Branches b ON b.Id = a.BranchId
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = a.SourceInvoiceId
    INNER JOIN masterdata.Parties sp ON sp.Id = inv.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = a.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = a.PostedBy
    WHERE (@Search IS NULL OR a.DocumentNumber LIKE N'%' + @Search + N'%' OR inv.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (@SourceInvoiceId IS NULL OR a.SourceInvoiceId = @SourceInvoiceId)
      AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND (@Status IS NULL OR a.Status = @Status)
      AND (@DateFrom IS NULL OR a.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR a.DocumentDate <= @DateTo)
    ORDER BY a.DocumentDate DESC, a.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Three result sets: header, charges (with their allocations summarised), lines (the split - filled at posting).
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.Id, a.DocumentNumber, a.DocumentDate, a.BranchId, b.BranchName, a.SourceInvoiceId, inv.DocumentNumber AS SourceInvoiceNumber,
           inv.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, inv.WarehouseId, w.WarehouseName,
           a.Notes, a.Status, a.TotalChargesBase, a.InventoryPortionBase, a.CogsPortionBase,
           a.PostedAtUtc, a.PostedBy, pu.FullName AS PostedByName, a.CancelledAtUtc, a.CancelReason,
           a.CreatedAtUtc, a.CreatedBy, cu.FullName AS CreatedByName, a.UpdatedAtUtc, a.RowVersion
    FROM purchase.LandedCostAdjustments a
    INNER JOIN masterdata.Branches b ON b.Id = a.BranchId
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = a.SourceInvoiceId
    INNER JOIN masterdata.Warehouses w ON w.Id = inv.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = inv.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = a.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = a.PostedBy
    WHERE a.Id = @Id;

    SELECT c.Id, c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id)
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    WHERE c.DocumentKind = N'LCA' AND c.DocumentId = @Id
    ORDER BY c.LineNumber;

    SELECT l.Id, l.PurchaseLineId, pl.LineNumber, l.ItemId, i.ItemCode, i.ItemName, l.WarehouseId, w.WarehouseCode,
           l.ReceivedBase, l.NetReceivedBase, l.RemainingBase, l.AllocatedBase, l.ExtraPerBaseUnit, l.InventoryPortionBase, l.CogsPortionBase,
           l.LandedCostBefore, l.LandedCostAfter
    FROM purchase.LandedCostAdjustmentLines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE l.AdjustmentId = @Id
    ORDER BY pl.LineNumber;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Save
    @Id                INT            = NULL,
    @SourceInvoiceId   INT,
    @DocumentDate      DATE,
    @Notes             NVARCHAR(1000) = NULL,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL THROW 67000, 'Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 67000, 'Date cannot be in the future.', 1;

    DECLARE @InvStatus TINYINT, @InvType NVARCHAR(20), @BranchId INT, @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SELECT @InvStatus = d.Status, @InvType = dt.Code, @BranchId = d.BranchId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceInvoiceId;
    IF @InvStatus IS NULL THROW 67011, 'Purchase invoice not found.', 1;
    IF @InvType <> N'PINV' OR @InvStatus <> 2 THROW 67011, 'Landed cost adjustments apply to POSTED purchase invoices only.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Charges) THROW 67000, 'At least one charge is required.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67005, 'Only draft adjustments can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND SourceInvoiceId <> @SourceInvoiceId)
            THROW 67000, 'The invoice of an adjustment cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'LCA');
            EXEC inventory.usp_DocumentType_NextNumber N'LCA', @Number OUTPUT, @BranchId;
            INSERT INTO purchase.LandedCostAdjustments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, SourceInvoiceId, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @SourceInvoiceId, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE purchase.LandedCostAdjustments SET DocumentDate = @DocumentDate, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        EXEC purchase.usp_PurchaseCharges_Write N'LCA', @Id, @DocumentDate, @BaseCurrency, @SourceInvoiceId, @Charges, @ManualAllocations, @UserId;

        UPDATE a SET TotalChargesBase = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id AND IncludeInLandedCost = 1), 0)
        FROM purchase.LandedCostAdjustments a WHERE a.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Posting: allocate over the invoice lines, split between stock still on hand (inventory value, average recalculated)
-- and quantity already sold (COGS adjustment), update the invoice lines' landed cost and the item's last cost.
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @Date DATE, @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @Date = DocumentDate, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67010, 'Only draft adjustments can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND Status = 2)
            THROW 67011, 'The purchase invoice is no longer posted.', 1;

        EXEC purchase.usp_PurchaseCharges_Allocate N'LCA', @Id, @InvoiceId;

        DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId);

        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        INSERT INTO purchase.LandedCostAdjustmentLines (AdjustmentId, PurchaseLineId, ItemId, WarehouseId, ReceivedBase, NetReceivedBase, RemainingBase,
                                                        AllocatedBase, ExtraPerBaseUnit, InventoryPortionBase, CogsPortionBase, LandedCostBefore, LandedCostAfter)
        SELECT @Id, l.Id, l.ItemId, l.WarehouseId, l.QuantityBase, n.NetReceived, r.Remaining,
               a.Allocated, a.Allocated / l.QuantityBase,
               InvPortion = ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               CogsPortion = a.Allocated - ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               l.UnitCostBase,
               ((l.LineTotal / @Rate) + l.AllocatedChargesBase + a.Allocated) / l.QuantityBase
        FROM purchase.PurchaseDocumentLines l
        CROSS APPLY (SELECT Allocated = ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                                 INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                 WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'LCA' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1), 0)) a
        CROSS APPLY (SELECT NetReceived = l.QuantityBase - l.ReturnedQuantityBase) n
        CROSS APPLY (SELECT Remaining = CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) < n.NetReceived
                                             THEN CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) > 0 THEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) ELSE 0 END
                                             ELSE n.NetReceived END) r
        WHERE l.DocumentId = @InvoiceId AND a.Allocated <> 0;

        -- Items with no stock at all: everything goes to COGS.
        UPDATE x SET CogsPortionBase = x.CogsPortionBase + x.InventoryPortionBase, InventoryPortionBase = 0
        FROM purchase.LandedCostAdjustmentLines x
        WHERE x.AdjustmentId = @Id AND inventory.fn_StockOnHand(x.ItemId, NULL) <= 0;

        -- Inventory value -> moving average (company-wide: value added / total on hand of the item).
        UPDATE i SET AverageCost = i.AverageCost + p.Inv / inventory.fn_StockOnHand(i.Id, NULL)
        FROM inventory.Items i
        INNER JOIN (SELECT ItemId, Inv = SUM(InventoryPortionBase) FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id GROUP BY ItemId) p ON p.ItemId = i.Id
        WHERE p.Inv <> 0 AND inventory.fn_StockOnHand(i.Id, NULL) > 0;

        -- Invoice lines / header carry the new landed cost.
        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase + x.AllocatedBase, UnitCostBase = x.LandedCostAfter
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- Last cost follows when this invoice is the item's latest posted purchase.
        UPDATE i SET LastCost = x.LandedCostAfter
        FROM inventory.Items i
        INNER JOIN purchase.LandedCostAdjustmentLines x ON x.ItemId = i.Id AND x.AdjustmentId = @Id
        WHERE @InvoiceId = (SELECT TOP (1) d.Id FROM purchase.PurchaseDocumentLines l
                            INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                            WHERE dt.Code = N'PINV' AND d.Status = 2 AND l.ItemId = i.Id ORDER BY d.PostedAtUtc DESC, l.Id DESC);

        -- Value ledger.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@Date AS DATETIME2(3))),
               x.ItemId, x.WarehouseId, @BranchId, k.Kind, k.Amount, N'LCA', @Id, @Number, x.PurchaseLineId, @UserId
        FROM purchase.LandedCostAdjustmentLines x
        CROSS APPLY (VALUES (N'Inventory', x.InventoryPortionBase), (N'COGS', x.CogsPortionBase)) k (Kind, Amount)
        WHERE x.AdjustmentId = @Id AND k.Amount <> 0;

        UPDATE a
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId,
            InventoryPortionBase = ISNULL(t.Inv, 0), CogsPortionBase = ISNULL(t.Cogs, 0)
        FROM purchase.LandedCostAdjustments a
        CROSS APPLY (SELECT SUM(InventoryPortionBase) AS Inv, SUM(CogsPortionBase) AS Cogs FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id) t
        WHERE a.Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', N'Landed cost adjustment ' + @Number + N' posted: ' + CAST((SELECT TotalChargesBase FROM purchase.LandedCostAdjustments WHERE Id = @Id) AS NVARCHAR(30)) + N' added to the landed cost', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 67000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 2 THROW 67010, 'Only posted adjustments can be cancelled.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;

        -- Reverse the value ledger and the invoice landed cost.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT SYSUTCDATETIME(), c.ItemId, c.WarehouseId, c.BranchId, c.Kind, -c.AmountBase, c.SourceKind, c.SourceId, c.SourceNumber, c.PurchaseLineId, @UserId
        FROM inventory.CostAdjustments c WHERE c.SourceKind = N'LCA' AND c.SourceId = @Id AND c.AmountBase > 0;

        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase - x.AllocatedBase, UnitCostBase = x.LandedCostBefore
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        UPDATE purchase.LandedCostAdjustments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@InvoiceId, N'Updated', N'Landed cost adjustment ' + @Number + N' cancelled: ' + @Reason, @UserId);

        -- Average / last cost recomputed from the ledger (the reversal rows net the adjustment out).
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        OPEN items; FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items; DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
    IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
    IF @Status <> 1 THROW 67005, 'Only draft adjustments can be deleted.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'LCA' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id;
        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        DELETE FROM purchase.LandedCostAdjustments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. purchase.usp_PurchaseDocument_Get re-created (cost columns + 6th result set: charges) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           TransitBase = CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV) and of its posted / draft adjustments (kind LCA), with the allocated total.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    ORDER BY c.DocumentKind, c.DocumentId, c.LineNumber;
END
GO

/* ================================================================== 9. Inventory In / Out: receipts do not touch Last Cost */

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        IF @Direction = -1
        BEGIN
            UPDATE l SET UnitCost = ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * l.PackingFormula
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

            UPDATE d SET TotalCost = x.Cost
            FROM inventory.StockDocuments d
            CROSS APPLY (SELECT ISNULL(SUM(LineTotal), 0) AS Cost FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula ELSE l.UnitCost END, NULL
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;      -- average yes, last / FOB cost no
        END

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 10. Sales: cost snapshots, return consumption, profit */

IF COL_LENGTH(N'sales.SalesDocumentLines', N'CogsBase') IS NULL
BEGIN
    ALTER TABLE sales.SalesDocumentLines ADD
        FobCostAtSale        DECIMAL(18,6) NULL,      -- item FOB cost at posting (analysis)
        LastCostAtSale       DECIMAL(18,6) NULL,      -- item last (landed) cost at posting (analysis)
        NetSalesBase         DECIMAL(18,2) NULL,      -- LineTotal / rate
        CogsBase             DECIMAL(18,2) NULL,      -- QuantityBase x UnitCostBase (frozen)
        GrossProfitBase      DECIMAL(18,2) NULL,
        GrossProfitPct       DECIMAL(9,2)  NULL,      -- on net sales
        ReturnedQuantityBase INT           NOT NULL CONSTRAINT DF_SalesDocumentLines_Returned DEFAULT (0);
    PRINT 'SalesDocumentLines: added cost / profit snapshot columns, ReturnedQuantityBase';
END
GO

IF COL_LENGTH(N'sales.SalesDocuments', N'TotalGrossProfitBase') IS NULL
BEGIN
    ALTER TABLE sales.SalesDocuments ADD TotalGrossProfitBase DECIMAL(18,2) NOT NULL CONSTRAINT DF_SalesDocuments_GrossProfit DEFAULT (0);
    PRINT 'SalesDocuments: added TotalGrossProfitBase';
END
GO

-- Backfill the snapshots of invoices posted before this script (COGS was already frozen per line).
UPDATE l
SET NetSalesBase = ROUND(l.LineTotal / d.ExchangeRate, 2),
    CogsBase = ROUND(l.QuantityBase * ISNULL(l.UnitCostBase, 0), 2),
    GrossProfitBase = ROUND(l.LineTotal / d.ExchangeRate, 2) - ROUND(l.QuantityBase * ISNULL(l.UnitCostBase, 0), 2),
    GrossProfitPct = CASE WHEN l.LineTotal > 0 THEN ROUND(100.0 * (ROUND(l.LineTotal / d.ExchangeRate, 2) - ROUND(l.QuantityBase * ISNULL(l.UnitCostBase, 0), 2)) / ROUND(l.LineTotal / d.ExchangeRate, 2), 2) END
FROM sales.SalesDocumentLines l
INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
WHERE d.Status IN (2, 3) AND l.CogsBase IS NULL;
UPDATE d SET TotalGrossProfitBase = ISNULL(x.Gp, 0)
FROM sales.SalesDocuments d
CROSS APPLY (SELECT SUM(GrossProfitBase) AS Gp FROM sales.SalesDocumentLines WHERE DocumentId = d.Id) x
WHERE d.Status IN (2, 3) AND d.TotalGrossProfitBase = 0 AND x.Gp IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @DraftReference     NVARCHAR(50)   = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT, @Rate DECIMAL(18,6);
    EXEC sales.usp_SalesDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
         @PriceListId, @RateType, @ExchangeRate, @MaxDiscountPercent, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT, @Rate OUTPUT;

    -- Source links of a return draft (SINV -> SRET) survive a re-save: kept by line number + item.
    DECLARE @Kept TABLE (LineNumber INT PRIMARY KEY, ItemId INT, SourceLineId INT, UnitCostBase DECIMAL(18,6));

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 64000, 'The document type cannot be changed.', 1;
        INSERT INTO @Kept (LineNumber, ItemId, SourceLineId, UnitCostBase)
        SELECT LineNumber, ItemId, SourceLineId, UnitCostBase FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL;
    END

    DECLARE @Priced TABLE
    (
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    CROSS APPLY (SELECT masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) AS Price) sp;

    -- Return lines created from an invoice keep the invoice price and discount (the customer is refunded what was paid).
    UPDATE p SET UnitPrice = s.UnitPrice, DiscountPercent = s.DiscountPercent, SystemPrice = s.UnitPrice
    FROM @Priced p
    INNER JOIN @Kept k ON k.LineNumber = p.LineNumber AND k.ItemId = p.ItemId
    INNER JOIN sales.SalesDocumentLines s ON s.Id = k.SourceLineId;

    DECLARE @NoPrice NVARCHAR(400);
    SELECT TOP (1) @NoPrice = N'Line ' + CAST(p.LineNumber AS NVARCHAR(10)) + N': no selling price for ' + i.ItemCode + N' (' + ut.UnitTypeName
                              + N') in price list ' + pl.PriceListName + N'. Add the price or enter a manual price (requires the price override permission).'
    FROM @Priced p
    INNER JOIN inventory.Items i       ON i.Id = p.ItemId
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = @PriceListId
    WHERE p.UnitPrice IS NULL
    ORDER BY p.LineNumber;
    IF @NoPrice IS NOT NULL THROW 64011, @NoPrice, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO sales.SalesDocuments (DocumentTypeId, DocumentNumber, DocumentDate, DueDate, BranchId, WarehouseId, ClientId, SalesmanId,
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE sales.SalesDocuments
            SET DocumentDate = @DocumentDate, DueDate = @DueDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                ClientId = @ClientId, SalesmanId = @SalesmanId, PriceListId = @PriceListId, CurrencyId = @CurrencyId,
                RateType = @RateType, ExchangeRate = @Rate, ReferenceNo = @ReferenceNo, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                              UnitPrice, DiscountPercent, PriceSource, UnitCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, @WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula,
               p.UnitPrice, p.DiscountPercent,
               CASE WHEN p.SystemPrice IS NULL OR p.UnitPrice <> p.SystemPrice THEN N'Manual' ELSE N'PriceList' END,
               k.UnitCostBase, p.ImportRowNumber, p.Notes, k.SourceLineId
        FROM @Priced p
        LEFT JOIN @Kept k ON k.LineNumber = p.LineNumber AND k.ItemId = p.ItemId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        IF @DraftReference IS NOT NULL
        BEGIN
            DECLARE @NewLogs TABLE (Id INT PRIMARY KEY, FileName NVARCHAR(255), ImportedRows INT);
            INSERT INTO @NewLogs (Id, FileName, ImportedRows)
            SELECT Id, FileName, ImportedRows FROM sales.InvoiceImportLogs WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;

            EXEC sales.usp_InvoiceImport_AttachInvoice @DraftReference, @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            SELECT @Id, N'Imported', N'Excel import: ' + FileName + N' (' + CAST(ImportedRows AS NVARCHAR(10)) + N' row(s))', @UserId
            FROM @NewLogs ORDER BY Id;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT,
                @Rate DECIMAL(18,6), @SourceId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocumentLines WHERE DocumentId = @Id)
            THROW 64009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

        -- A return created from an invoice cannot exceed what that invoice line still holds.
        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 64010, 'The original invoice is no longer posted.', 1;
            SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                 + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
            FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
            INNER JOIN sales.SalesDocumentLines s ON s.Id = x.SourceLineId
            INNER JOIN inventory.Items i ON i.Id = s.ItemId
            WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
            ORDER BY x.LineNumber;
            IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- Frozen cost snapshots: invoices take the moving average; returns keep the original invoice COGS (fallback: average).
        UPDATE l
        SET UnitCostBase = ISNULL(CASE WHEN @Direction = 1 THEN l.UnitCostBase END, ISNULL(i.AverageCost, 0)),
            FobCostAtSale = i.FobCost, LastCostAtSale = i.LastCost
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE l.DocumentId = @Id;

        UPDATE l
        SET NetSalesBase = ROUND(l.LineTotal / @Rate, 2),
            CogsBase = ROUND(l.QuantityBase * l.UnitCostBase, 2),
            GrossProfitBase = ROUND(l.LineTotal / @Rate, 2) - ROUND(l.QuantityBase * l.UnitCostBase, 2),
            GrossProfitPct = CASE WHEN l.LineTotal > 0 THEN ROUND(100.0 * (ROUND(l.LineTotal / @Rate, 2) - ROUND(l.QuantityBase * l.UnitCostBase, 2)) / ROUND(l.LineTotal / @Rate, 2), 2) END
        FROM sales.SalesDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), NULL FROM sales.SalesDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            WHERE l.DocumentId = @Id;
        END

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE d
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            TotalCostBase = ISNULL(x.Cost, 0), TotalGrossProfitBase = ISNULL(x.Gp, 0), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT SUM(CogsBase) AS Cost, SUM(GrossProfitBase) AS Gp FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM sales.SalesDocumentLines WHERE DocumentId = @Id);
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT, @TypeCode NVARCHAR(20), @SourceId INT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @TypeCode = dt.Code, @SourceId = d.SourceDocumentId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE SourceDocumentId = @Id AND Status = 2)
            THROW 64010, 'This invoice cannot be cancelled: posted returns refer to it. Cancel those first.', 1;

        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled return was a receipt: replay the cost history of its items.
        IF @Direction = 1
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.DueDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Phone AS ClientPhone, cl.Email AS ClientEmail, cl.Address AS ClientAddress,
           d.SalesmanId, sm.PartyCode AS SalesmanCode, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListCode, pl.PriceListName,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.ReferenceNo, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalCostBase, d.TotalGrossProfitBase,
           TotalGrossProfitPct = CASE WHEN d.TotalAmountBase > 0 THEN ROUND(100.0 * d.TotalGrossProfitBase / d.TotalAmountBase, 2) END,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN sales.SalesDocuments src   ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal, l.PriceSource,
           l.UnitCostBase, l.FobCostAtSale, l.LastCostAtSale, l.NetSalesBase, l.CogsBase, l.GrossProfitBase, l.GrossProfitPct,
           l.ReturnedQuantityBase, RemainingBase = l.QuantityBase - l.ReturnedQuantityBase,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           SystemPrice = masterdata.fn_GetUnitPrice(l.ItemUnitId, d.PriceListId, d.BranchId),
           ItemAverageCost = i.AverageCost
    FROM sales.SalesDocumentLines l
    INNER JOIN sales.SalesDocuments d   ON d.Id = l.DocumentId
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.SalesDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.SalesDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

-- Sales return draft from a posted invoice: remaining quantities, invoice prices, ORIGINAL COGS per line.
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_CreateFromSource
    @SourceId     INT,
    @DocumentDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @ClientId INT, @SalesmanId INT, @PriceListId INT, @RateType TINYINT, @Rate DECIMAL(18,6), @Ref NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @ClientId = d.ClientId, @SalesmanId = d.SalesmanId,
           @PriceListId = d.PriceListId, @RateType = d.RateType, @Rate = d.ExchangeRate, @Ref = d.DocumentNumber
    FROM sales.SalesDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;
    IF @SrcType IS NULL THROW 64006, 'Source invoice not found.', 1;
    IF @SrcType <> N'SINV' OR @Status <> 2 THROW 64010, 'Returns are created from POSTED sales invoices only.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'SRET' AND IsActive = 1) THROW 64008, 'Document type SRET is inactive.', 1;

    DECLARE @Lines sales.tvp_SalesDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate, c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes
    FROM sales.SalesDocumentLines l
    CROSS APPLY (SELECT Remaining = l.QuantityBase - l.ReturnedQuantityBase) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 64010, 'Everything on this invoice was already returned.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Saved with the override allowed so the invoice prices are kept as given; then linked to the source lines.
        EXEC sales.usp_SalesDocument_Save @Id = NULL, @DocumentTypeCode = N'SRET', @DocumentDate = @DocumentDate, @DueDate = NULL,
             @BranchId = @BranchId, @WarehouseId = @WarehouseId, @ClientId = @ClientId, @SalesmanId = @SalesmanId, @PriceListId = @PriceListId,
             @RateType = @RateType, @ExchangeRate = @Rate, @ReferenceNo = @Ref, @Notes = NULL, @Lines = @Lines,
             @AllowPriceOverride = 1, @MaxDiscountPercent = 100, @DraftReference = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE n
        SET SourceLineId = s.Id, UnitCostBase = s.UnitCostBase
        FROM sales.SalesDocumentLines n
        INNER JOIN (SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber) AS Rn, l.Id, l.UnitCostBase
                    FROM sales.SalesDocumentLines l WHERE l.DocumentId = @SourceId AND l.QuantityBase - l.ReturnedQuantityBase > 0) s ON s.Rn = n.LineNumber
        WHERE n.DocumentId = @NewId;

        UPDATE sales.SalesDocuments SET SourceDocumentId = @SourceId WHERE Id = @NewId;
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@NewId, N'Created', N'Return draft created from ' + @Ref, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 11. Sales profit report (frozen costs) */

-- Net Sales, COGS, Gross Profit and GP % in the base currency from the posted invoice lines (returns subtract),
-- plus the COGS adjustments of landed cost adjustments in the period (separate column - they belong to no invoice).
CREATE OR ALTER PROCEDURE sales.usp_SalesProfit_Report
    @DateFrom     DATE         = NULL,
    @DateTo       DATE         = NULL,
    @BranchId     INT          = NULL,
    @ClientId     INT          = NULL,
    @SalesmanId   INT          = NULL,
    @ItemFamilyId INT          = NULL,
    @BrandId      INT          = NULL,
    @ItemId       INT          = NULL,
    @GroupBy      NVARCHAR(20) = N'Invoice'   -- Invoice | Item | Family | Brand | Client | Salesman | Branch | Month | All
AS
BEGIN
    SET NOCOUNT ON;
    IF @GroupBy IS NULL OR @GroupBy NOT IN (N'Invoice', N'Item', N'Family', N'Brand', N'Client', N'Salesman', N'Branch', N'Month', N'All') SET @GroupBy = N'Invoice';

    ;WITH lines AS
    (
        SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchName, d.ClientId, cl.PartyName AS ClientName,
               d.SalesmanId, sm.PartyName AS SalesmanName, l.ItemId, i.ItemCode, i.ItemName, i.ItemFamilyId, f.FamilyName, i.BrandId, br.BrandName,
               Sign = CASE WHEN dt.Code = N'SRET' THEN -1 ELSE 1 END,
               l.QuantityBase, GrossBase = ROUND(l.Quantity * l.UnitPrice / d.ExchangeRate, 2), l.NetSalesBase, l.CogsBase, l.GrossProfitBase
        FROM sales.SalesDocumentLines l
        INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
        INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
        INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
        INNER JOIN masterdata.Parties cl ON cl.Id = d.ClientId
        LEFT  JOIN masterdata.Parties sm ON sm.Id = d.SalesmanId
        WHERE d.Status = 2 AND dt.Code IN (N'SINV', N'SRET')
          AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
          AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
          AND (@ClientId IS NULL OR d.ClientId = @ClientId)
          AND (@SalesmanId IS NULL OR d.SalesmanId = @SalesmanId)
          AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
          AND (@BrandId IS NULL OR i.BrandId = @BrandId)
          AND (@ItemId IS NULL OR l.ItemId = @ItemId)
    ),
    keyed AS
    (
        SELECT *,
               GroupKey = CASE @GroupBy WHEN N'Invoice' THEN CAST(DocumentId AS NVARCHAR(30)) WHEN N'Item' THEN CAST(ItemId AS NVARCHAR(30))
                                        WHEN N'Family' THEN CAST(ItemFamilyId AS NVARCHAR(30)) WHEN N'Brand' THEN CAST(BrandId AS NVARCHAR(30))
                                        WHEN N'Client' THEN CAST(ClientId AS NVARCHAR(30)) WHEN N'Salesman' THEN CAST(ISNULL(SalesmanId, 0) AS NVARCHAR(30))
                                        WHEN N'Branch' THEN CAST(BranchId AS NVARCHAR(30)) WHEN N'Month' THEN CONVERT(NVARCHAR(7), DocumentDate, 120) ELSE N'ALL' END,
               GroupLabel = CASE @GroupBy WHEN N'Invoice' THEN DocumentNumber WHEN N'Item' THEN ItemCode + N' - ' + ItemName WHEN N'Family' THEN FamilyName
                                          WHEN N'Brand' THEN BrandName WHEN N'Client' THEN ClientName WHEN N'Salesman' THEN ISNULL(SalesmanName, N'(no salesman)')
                                          WHEN N'Branch' THEN BranchName WHEN N'Month' THEN CONVERT(NVARCHAR(7), DocumentDate, 120) ELSE N'All' END
        FROM lines
    )
    SELECT k.GroupKey, k.GroupLabel,
           InvoiceCount   = COUNT(DISTINCT CASE WHEN k.Sign = 1 THEN k.DocumentId END),
           ReturnCount    = COUNT(DISTINCT CASE WHEN k.Sign = -1 THEN k.DocumentId END),
           QuantityBase   = SUM(k.Sign * k.QuantityBase),
           GrossSalesBase = SUM(k.Sign * k.GrossBase),
           DiscountBase   = SUM(k.Sign * (k.GrossBase - ISNULL(k.NetSalesBase, 0))),
           NetSalesBase   = SUM(k.Sign * ISNULL(k.NetSalesBase, 0)),
           CogsBase       = SUM(k.Sign * ISNULL(k.CogsBase, 0)),
           GrossProfitBase = SUM(k.Sign * ISNULL(k.GrossProfitBase, 0)),
           GrossProfitPct = CASE WHEN SUM(k.Sign * ISNULL(k.NetSalesBase, 0)) <> 0
                                 THEN ROUND(100.0 * SUM(k.Sign * ISNULL(k.GrossProfitBase, 0)) / SUM(k.Sign * ISNULL(k.NetSalesBase, 0)), 2) END,
           CogsAdjustmentsBase = CASE WHEN @GroupBy IN (N'All', N'Month', N'Branch', N'Item', N'Family', N'Brand')
                                      THEN ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                                                   INNER JOIN inventory.Items ci ON ci.Id = c.ItemId
                                                   WHERE c.Kind = N'COGS'
                                                     AND (@DateFrom IS NULL OR CAST(c.AdjustmentDate AS DATE) >= @DateFrom)
                                                     AND (@DateTo IS NULL OR CAST(c.AdjustmentDate AS DATE) <= @DateTo)
                                                     AND (@BranchId IS NULL OR c.BranchId = @BranchId)
                                                     AND (@ItemFamilyId IS NULL OR ci.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
                                                     AND (@BrandId IS NULL OR ci.BrandId = @BrandId)
                                                     AND (@ItemId IS NULL OR c.ItemId = @ItemId)
                                                     AND (@GroupBy <> N'Month' OR CONVERT(NVARCHAR(7), c.AdjustmentDate, 120) = k.GroupKey)
                                                     AND (@GroupBy <> N'Branch' OR CAST(c.BranchId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Item' OR CAST(c.ItemId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Family' OR CAST(ci.ItemFamilyId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Brand' OR CAST(ci.BrandId AS NVARCHAR(30)) = k.GroupKey)), 0)
                                      ELSE 0 END
    FROM keyed k
    GROUP BY k.GroupKey, k.GroupLabel
    ORDER BY CASE WHEN @GroupBy IN (N'Invoice', N'Month') THEN k.GroupKey END DESC, k.GroupLabel;
END
GO

/* ================================================================== 12. Permissions + report */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'purchase.chargetypes.manage', N'Manage purchase charge types', N'Configuration', N'Define charge types and their allocation rules.',          910),
        (N'purchase.landedcosts.view',   N'View Landed Cost Adjustments',   N'Purchase', N'See landed cost adjustments.',                               1180),
        (N'purchase.landedcosts.create', N'Create Landed Cost Adjustments', N'Purchase', N'Create and edit draft landed cost adjustments.',             1190),
        (N'purchase.landedcosts.post',   N'Post Landed Cost Adjustments',   N'Purchase', N'Post landed cost adjustments (updates item costs).',         1200),
        (N'purchase.landedcosts.cancel', N'Cancel Landed Cost Adjustments', N'Purchase', N'Cancel posted landed cost adjustments.',                     1210),
        (N'purchase.landedcosts.delete', N'Delete Landed Cost Adjustments', N'Purchase', N'Delete draft landed cost adjustments.',                      1220),
        (N'sales.profit.view',           N'View Sales Profit',              N'Sales',    N'See the sales profit report (net sales, COGS, gross profit).', 680)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'purchase.landedcosts.%' OR p.Code IN (N'purchase.chargetypes.manage', N'sales.profit.view'))
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'purchase.landedcosts.view', N'sales.profit.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO
