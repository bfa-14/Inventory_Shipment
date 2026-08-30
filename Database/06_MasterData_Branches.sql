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

USE [Inventory_Shipment];
GO

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

/* ------------------------------------------------------------------ 5. Report */

SELECT Id, BranchCode, BranchName, Address, IsMainBranch, IsActive, CreatedAtUtc
FROM masterdata.Branches
ORDER BY BranchCode;

SELECT p.Code, STUFF((SELECT N', ' + r.Name
                      FROM security.RolePermissions rp
                      INNER JOIN security.Roles r ON r.Id = rp.RoleId
                      WHERE rp.PermissionId = p.Id
                      ORDER BY r.Name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM security.Permissions p
WHERE p.Code LIKE N'masterdata.branches.%'
ORDER BY p.SortOrder;

PRINT 'Master Data - Branches is ready.';
GO
