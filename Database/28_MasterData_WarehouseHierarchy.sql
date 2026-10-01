/* =====================================================================================
   Inventory_Shipment - 28: Master Data - a warehouse may stand under another warehouse

   Warehouses gain the shape Item Families already have: ParentId and Level, so a
   warehouse can be a grouping ("Main Warehouse") with real storage places beneath it.

   TWO DECISIONS ARE BUILT INTO THIS, and both were the customer's:

     - STOCK LIVES ON THE LEAVES. A parent is a heading, not a place: documents, on-hand
       and valuation name a warehouse with no children. What a parent holds is the sum of
       what stands under it, so "how much is in Main Warehouse" has exactly one answer.
       This script adds the shape; the document procedures keep their own warehouse rules.

     - A CHILD MAY BELONG TO ANY BRANCH. The tree and the branch are two different
       questions - where a place sits in the storage hierarchy, and which site owns it -
       and nothing here forces them to agree.

   Sibling names are deliberately NOT made unique the way family names are: warehouse
   codes are already unique across the table, and existing rows may share a name.

   Errors raised (52xxx is the warehouse block):
     52000 validation      52001 duplicate code     52003 referenced
     52004 concurrency     52006 not found          52008 circular hierarchy (new)
   ===================================================================================== */

/* ------------------------------------------------------------------ 1. Columns */

IF COL_LENGTH(N'masterdata.Warehouses', N'ParentId') IS NULL
BEGIN
    ALTER TABLE masterdata.Warehouses ADD ParentId INT NULL;
    PRINT 'Warehouses: added ParentId';
END
GO

IF COL_LENGTH(N'masterdata.Warehouses', N'Level') IS NULL
BEGIN
    -- 1 = a root warehouse. Maintained by the procedures below, never by hand.
    ALTER TABLE masterdata.Warehouses ADD [Level] INT NOT NULL CONSTRAINT DF_Warehouses_Level DEFAULT (1);
    PRINT 'Warehouses: added Level';
END
GO

IF OBJECT_ID(N'masterdata.FK_Warehouses_Parent', N'F') IS NULL
BEGIN
    -- No cascade: a parent with children is refused rather than taking them down with it.
    ALTER TABLE masterdata.Warehouses
        ADD CONSTRAINT FK_Warehouses_Parent FOREIGN KEY (ParentId) REFERENCES masterdata.Warehouses (Id);
    PRINT 'Warehouses: added FK_Warehouses_Parent';
END
GO

IF OBJECT_ID(N'masterdata.CK_Warehouses_NotOwnParent', N'C') IS NULL
BEGIN
    ALTER TABLE masterdata.Warehouses
        ADD CONSTRAINT CK_Warehouses_NotOwnParent CHECK (ParentId IS NULL OR ParentId <> Id);
    PRINT 'Warehouses: added CK_Warehouses_NotOwnParent';
END
GO

IF OBJECT_ID(N'masterdata.CK_Warehouses_Level', N'C') IS NULL
BEGIN
    ALTER TABLE masterdata.Warehouses ADD CONSTRAINT CK_Warehouses_Level CHECK ([Level] >= 1);
    PRINT 'Warehouses: added CK_Warehouses_Level';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Warehouses_ParentId' AND object_id = OBJECT_ID(N'masterdata.Warehouses'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Warehouses_ParentId ON masterdata.Warehouses (ParentId);
    PRINT 'Warehouses: added IX_Warehouses_ParentId';
END
GO

/* ------------------------------------------------------------------ 2. Subtree */

-- A warehouse plus every descendant, with its depth below the one asked for (0 = itself).
-- Iterative rather than recursive, so it works at ANY depth without a MAXRECURSION hint.
CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_Subtree (@Id INT)
RETURNS @Subtree TABLE (Id INT PRIMARY KEY, Depth INT NOT NULL)
AS
BEGIN
    INSERT INTO @Subtree (Id, Depth) VALUES (@Id, 0);

    DECLARE @Depth INT = 0;

    WHILE EXISTS (SELECT 1 FROM @Subtree WHERE Depth = @Depth)
    BEGIN
        INSERT INTO @Subtree (Id, Depth)
        SELECT w.Id, @Depth + 1
        FROM masterdata.Warehouses w
        INNER JOIN @Subtree s ON s.Id = w.ParentId AND s.Depth = @Depth
        -- A row already seen cannot be added twice, so a cycle left by older data stops here
        -- instead of spinning forever.
        WHERE NOT EXISTS (SELECT 1 FROM @Subtree x WHERE x.Id = w.Id);

        SET @Depth = @Depth + 1;
    END

    RETURN;
END
GO

/* ------------------------------------------------------------------ 3. Reading */

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName,
           w.IsMainWarehouse, w.IsActive, w.ParentId, w.[Level],
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE (@ActiveOnly = 0 OR w.IsActive = 1 OR w.Id = @IncludeId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
    ORDER BY w.IsMainWarehouse DESC, w.WarehouseName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Search
    @Search          NVARCHAR(150) = NULL,
    @BranchId        INT           = NULL,
    @IsActive        BIT           = NULL,
    @IsMainWarehouse BIT           = NULL,
    @SortColumn      NVARCHAR(30)  = N'WarehouseCode',
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
           w.ParentId, w.[Level],
           ParentCode = p.WarehouseCode,
           ParentName = p.WarehouseName,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    LEFT  JOIN masterdata.Warehouses p ON p.Id = w.ParentId
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
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion,
           w.ParentId, w.[Level],
           ParentCode = p.WarehouseCode,
           ParentName = p.WarehouseName,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    LEFT  JOIN masterdata.Warehouses p ON p.Id = w.ParentId
    WHERE w.Id = @Id;
END
GO

/* ------------------------------------------------------------------ 4. Writing */

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Create
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,
    @ParentId             INT           = NULL,   -- NULL = a root warehouse
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

    -- The parent need not share the branch: the tree and the branch answer different questions.
    IF @ParentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId)
        THROW 52000, 'The selected parent warehouse does not exist.', 1;

    IF @IsMainWarehouse = 1 AND @IsActive = 0
        THROW 52005, 'The Main Warehouse must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @WarehouseCode)
        THROW 52001, 'A warehouse with this Warehouse Code already exists.', 1;

    DECLARE @Level INT = 1;
    IF @ParentId IS NOT NULL
        SET @Level = (SELECT [Level] + 1 FROM masterdata.Warehouses WHERE Id = @ParentId);

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

        INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive, ParentId, [Level], CreatedBy)
        VALUES (@WarehouseCode, @WarehouseName, @BranchId, @Address, @IsMainWarehouse, @IsActive, @ParentId, @Level, @UserId);

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
    @ParentId             INT           = NULL,
    @RowVersion           BINARY(8)     = NULL,
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

    IF @BranchId <> @CurrentBranchId AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 52007, 'The selected Branch / Site does not exist or is inactive. Select an active branch.', 1;

    IF @IsMainWarehouse = 1 AND @IsActive = 0
        THROW 52005, 'The Main Warehouse must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @WarehouseCode AND Id <> @Id)
        THROW 52001, 'A warehouse with this Warehouse Code already exists.', 1;

    IF @ParentId IS NOT NULL
    BEGIN
        IF @ParentId = @Id
            THROW 52008, 'A warehouse cannot be its own parent.', 1;

        IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId)
            THROW 52000, 'The selected parent warehouse does not exist.', 1;

        -- The move that would swallow the mover: the chosen parent stands under this warehouse.
        IF EXISTS (SELECT 1 FROM masterdata.fn_Warehouse_Subtree(@Id) WHERE Id = @ParentId)
            THROW 52008, 'This would create a circular hierarchy: the selected parent stands under this warehouse.', 1;
    END

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 52004, 'This warehouse was modified by another user. Reload the page and try again.', 1;

    DECLARE @NewLevel INT = 1;
    IF @ParentId IS NOT NULL
        SET @NewLevel = (SELECT [Level] + 1 FROM masterdata.Warehouses WHERE Id = @ParentId);

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
            ParentId        = @ParentId,
            UpdatedAtUtc    = SYSUTCDATETIME(),
            UpdatedBy       = @UserId
        WHERE Id = @Id;

        /* THE WHOLE SUBTREE MOVES WITH IT. A warehouse carried to a new parent takes its
           children along, and their Level is their depth below it - left alone they would keep
           the depth they had under the old parent and the tree would draw at the wrong indent. */
        UPDATE w
        SET w.[Level] = @NewLevel + s.Depth
        FROM masterdata.Warehouses w
        INNER JOIN masterdata.fn_Warehouse_Subtree(@Id) s ON s.Id = w.Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deleted. Designate another warehouse as the Main Warehouse first.', 1;

    /* Said before the generic reference scan below, which would otherwise report a warehouse with
       children as "contains inventory or is referenced by other records" - true, but not the thing
       the reader has to fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @Id)
        THROW 52003, 'This warehouse has warehouses standing under it. Move or delete them first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Warehouses')
      -- ParentId is handled above, in its own words.
      AND NOT (t.object_id = OBJECT_ID(N'masterdata.Warehouses') AND c.name = N'ParentId');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 52003, 'This warehouse cannot be deleted because it contains inventory or is referenced by other records. You may deactivate the warehouse instead.', 1;

    DELETE FROM masterdata.Warehouses WHERE Id = @Id;
END
GO
