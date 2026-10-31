--      ticks are cleared); 0 = only @WarehouseIds (comma-separated; blanks ignored, duplicates once; none = moves stock
--      nowhere, A13). A ticked warehouse under another ticked one is dropped: the parent covers it. One history row
--      when the words change (two equal saves: one row). No row version (A11): the last save wins. No result set: the
--      API re-reads with usp_User_Warehouses_Get. 50011 the dialog's refusals; 50003 user not found.
CREATE   PROCEDURE security.usp_User_SetWarehouses
    @UserId        INT,
    @AllWarehouses BIT,
    @WarehouseIds  NVARCHAR(MAX) = NULL,
    @ChangedBy     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @Current BIT, @Before NVARCHAR(1000), @After NVARCHAR(1000), @Steps INT = 0;

    -- 1. All warehouses or a choice
    IF @AllWarehouses IS NULL
        THROW 50011, 'Choose All warehouses, or tick the warehouses this user may use.', 1;

    -- 2. The ids (only for "Only these warehouses")
    DECLARE @Asked TABLE (Value NVARCHAR(4000) NOT NULL, WarehouseId INT NULL);
    DECLARE @Want TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF @AllWarehouses = 0
    BEGIN
        INSERT INTO @Asked (Value, WarehouseId)
        SELECT DISTINCT LTRIM(RTRIM(s.value)), w.Id
        FROM STRING_SPLIT(ISNULL(@WarehouseIds, N''), N',') s
        LEFT JOIN masterdata.Warehouses w ON w.Id = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
        WHERE LTRIM(RTRIM(s.value)) <> N'';

        SELECT TOP (1) @Msg = N'Warehouse #' + LEFT(a.Value, 50) + N' was not found: reload the page and try again.'
        FROM @Asked a
        WHERE a.WarehouseId IS NULL
        ORDER BY CASE WHEN TRY_CAST(a.Value AS INT) IS NULL THEN 0 ELSE 1 END, TRY_CAST(a.Value AS INT), a.Value;
        IF @Msg IS NOT NULL THROW 50011, @Msg, 1;

        SELECT TOP (1) @Msg = w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and is never given to a user.'
        FROM @Asked a
        INNER JOIN masterdata.Warehouses w ON w.Id = a.WarehouseId
        WHERE w.IsTransit = 1
        ORDER BY w.WarehouseCode;
        IF @Msg IS NOT NULL THROW 50011, @Msg, 1;

        INSERT INTO @Want (WarehouseId) SELECT DISTINCT WarehouseId FROM @Asked;

        -- 3. A warehouse whose ancestor is ticked too is dropped: the parent covers it (A2)
        DECLARE @Up TABLE (WarehouseId INT NOT NULL, AncestorId INT NOT NULL, Steps INT NOT NULL, PRIMARY KEY (WarehouseId, AncestorId));
        INSERT INTO @Up (WarehouseId, AncestorId, Steps)
        SELECT w.Id, w.ParentId, 1
        FROM @Want x INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
        WHERE w.ParentId IS NOT NULL;
        WHILE @@ROWCOUNT > 0 AND @Steps < 100      -- a cycle left by old data stops here
        BEGIN
            SET @Steps += 1;
            INSERT INTO @Up (WarehouseId, AncestorId, Steps)
            SELECT u.WarehouseId, p.ParentId, @Steps + 1
            FROM @Up u
            INNER JOIN masterdata.Warehouses p ON p.Id = u.AncestorId
            WHERE u.Steps = @Steps AND p.ParentId IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM @Up x WHERE x.WarehouseId = u.WarehouseId AND x.AncestorId = p.ParentId);
        END
        DECLARE @Covered TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
        INSERT INTO @Covered (WarehouseId)
        SELECT DISTINCT u.WarehouseId FROM @Up u WHERE u.AncestorId IN (SELECT WarehouseId FROM @Want);
        DELETE FROM @Want WHERE WarehouseId IN (SELECT WarehouseId FROM @Covered);
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 4. The user, locked until the commit (two saves of one user follow each other; the last one wins)
        SELECT @Current = AllWarehouses FROM security.Users WITH (UPDLOCK, HOLDLOCK) WHERE Id = @UserId;
        IF @Current IS NULL THROW 50003, 'User not found.', 1;
        SET @Before = security.fn_User_WarehouseAccessText(@UserId);

        UPDATE security.Users SET AllWarehouses = @AllWarehouses, UpdatedAtUtc = SYSUTCDATETIME() WHERE Id = @UserId;

        DELETE FROM security.UserWarehouses
        WHERE UserId = @UserId
          AND (@AllWarehouses = 1 OR WarehouseId NOT IN (SELECT WarehouseId FROM @Want));

        IF @AllWarehouses = 0
            INSERT INTO security.UserWarehouses (UserId, WarehouseId, GrantedBy)
            SELECT @UserId, x.WarehouseId, @ChangedBy
            FROM @Want x
            WHERE NOT EXISTS (SELECT 1 FROM security.UserWarehouses uw WHERE uw.UserId = @UserId AND uw.WarehouseId = x.WarehouseId);

        SET @After = security.fn_User_WarehouseAccessText(@UserId);
        IF @After <> @Before
            INSERT INTO security.UserWarehouseAudit (UserId, BeforeText, AfterText, ChangedBy)
            VALUES (@UserId, @Before, @After, @ChangedBy);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

