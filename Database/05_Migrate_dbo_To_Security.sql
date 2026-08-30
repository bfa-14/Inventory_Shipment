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

USE [Inventory_Shipment];
GO

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

/* report */
SELECT s.name AS [schema], o.name AS [object], o.type_desc
FROM sys.objects o
INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.name IN (N'Users', N'RefreshTokens', N'LoginAudit', N'Roles', N'Permissions', N'RolePermissions', N'UserRoles',
                 N'fn_UserRoles', N'fn_UserPermissions', N'fn_UserHasPermission',
                 N'usp_Permission_SyncCatalog', N'usp_User_GetAccess', N'usp_User_SetRoles',
                 N'usp_Role_SetPermissions', N'usp_Role_Delete')
ORDER BY s.name, o.type_desc, o.name;
GO
