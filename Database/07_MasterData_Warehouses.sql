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

USE [Inventory_Shipment];
GO

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

/* ------------------------------------------------------------------ 6. Report */

SELECT w.Id, w.WarehouseCode, w.WarehouseName, b.BranchCode, b.BranchName, w.Address, w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc
FROM masterdata.Warehouses w
INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
ORDER BY w.WarehouseCode;

SELECT p.Code, STUFF((SELECT N', ' + r.Name
                      FROM security.RolePermissions rp
                      INNER JOIN security.Roles r ON r.Id = rp.RoleId
                      WHERE rp.PermissionId = p.Id
                      ORDER BY r.Name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM security.Permissions p
WHERE p.Code LIKE N'masterdata.warehouses.%'
ORDER BY p.SortOrder;

PRINT 'Master Data - Warehouses is ready.';
GO
