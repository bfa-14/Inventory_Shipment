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

/* ------------------------------------------------------------------ 6. Report */

SELECT Id, ParentId, FamilyCode, FamilyName, [Level], IsActive
FROM masterdata.ItemFamilies
ORDER BY [Level], FamilyCode;

SELECT p.Code, STUFF((SELECT N', ' + r.Name
                      FROM security.RolePermissions rp
                      INNER JOIN security.Roles r ON r.Id = rp.RoleId
                      WHERE rp.PermissionId = p.Id
                      ORDER BY r.Name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM security.Permissions p
WHERE p.Code LIKE N'masterdata.itemfamilies.%'
ORDER BY p.SortOrder;

PRINT 'Master Data - Item Families is ready.';
GO
