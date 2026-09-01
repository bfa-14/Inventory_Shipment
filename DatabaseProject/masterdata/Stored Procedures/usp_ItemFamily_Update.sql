CREATE   PROCEDURE masterdata.usp_ItemFamily_Update
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