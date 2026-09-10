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
