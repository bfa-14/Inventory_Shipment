/* (92) CHANGE A WAREHOUSE (script 91's rules), + moving it to another parent changes who may use it. */
-- Re-created (91) from the body of script 90: + the levels sentence of the used-parent refusal (52000) when the new
-- parent is used only through its stock levels (fn_Warehouse_IsUsedInTransactions = 0); otherwise today's sentence.
-- Re-created (92) from the body of script 91: + a move to another parent that changes the warehouses of users with "Only
-- these warehouses" (a ticked parent gives its whole tree, read at check time: A2) needs an editor who may use every
-- warehouse and holds security.users.edit (A12) - 50010 otherwise, so a restricted user can never give himself a
-- warehouse by moving it under one of his - and writes a history row for each of those users (W11), in the update's
-- transaction. Every other check, message and effect unchanged.
CREATE   PROCEDURE masterdata.usp_Warehouse_Update
    @Id                   INT,
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,
    @ParentId             INT           = NULL,
    @AllowOutOfStockOverride BIT        = NULL,   -- NULL = follow the global setting
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

    -- (90) THE BRANCH'S ON THE WAY WAREHOUSE belongs to transfers: its name and address may change, nothing else (the
    --      code compared exactly, so not even its case changes).
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses w
               WHERE w.Id = @Id AND w.IsTransit = 1
                 AND (   @WarehouseCode COLLATE Latin1_General_BIN2 <> w.WarehouseCode COLLATE Latin1_General_BIN2
                      OR @BranchId <> w.BranchId
                      OR @ParentId IS NOT NULL
                      OR @IsMainWarehouse <> w.IsMainWarehouse
                      OR @IsActive <> w.IsActive
                      OR ISNULL(CAST(@AllowOutOfStockOverride AS TINYINT), 2) <> ISNULL(CAST(w.AllowOutOfStockOverride AS TINYINT), 2)))
    BEGIN
        DECLARE @TransitMsg NVARCHAR(400) = (SELECT w.WarehouseCode + N' is the On the way warehouse of ' + b.BranchCode + N': transfers use it. Only its name and address can be changed.'
                                             FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                             WHERE w.Id = @Id);
        THROW 52009, @TransitMsg, 1;
    END

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
        -- (90) an On the way warehouse holds goods on the road, never other warehouses
        IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId AND IsTransit = 1)
            THROW 52000, 'An On the way warehouse cannot hold other warehouses. Choose another parent warehouse.', 1;
        -- Only a NEW parent is checked: a warehouse already standing under a used one keeps its place.
        IF @ParentId <> ISNULL((SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Id), 0)
           AND masterdata.fn_Warehouse_IsUsed(@ParentId) = 1
        BEGIN
            -- (91) a parent used only through its stock levels (no stock, no document) is told so, with its count of items
            DECLARE @UsedMsg NVARCHAR(400) =
                CASE WHEN masterdata.fn_Warehouse_IsUsedInTransactions(@ParentId) = 0
                     THEN N'Warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ParentId) + N' has stock levels for '
                          + CAST((SELECT COUNT(DISTINCT lv.ItemId) FROM inventory.ItemWarehouseLevels lv WHERE lv.WarehouseId = @ParentId) AS NVARCHAR(10))
                          + N' item(s), so it cannot become a parent: stock levels, like stock, are kept only in the warehouses at the bottom of the tree. Remove its levels (Inventory '
                          + NCHAR(8250) + N' Stock Levels), or choose another parent warehouse.'
                     ELSE N'Warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ParentId) + N' is already used in transactions, so it cannot become a parent: stock is kept only in the warehouses at the bottom of the tree. Choose another parent warehouse.' END;
            THROW 52000, @UsedMsg, 1;
        END
    END

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 52004, 'This warehouse was modified by another user. Reload the page and try again.', 1;

    -- (92) WHO MAY USE IT, WHEN IT MOVES TO ANOTHER PARENT. The warehouse and everything under it leave the users who
    --      ticked a warehouse above its old place and come to those who ticked one above its new place. A user counts
    --      when that changes what they may use: "Only these warehouses", a tick above exactly one of the two places, and
    --      no tick on the warehouse itself (which keeps its whole tree wherever it stands). Ticks on warehouses under it
    --      move with it.
    DECLARE @OldParentId INT = (SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Id);
    DECLARE @AccessMoved TABLE (UserId INT NOT NULL PRIMARY KEY, Gains BIT NOT NULL);
    IF ISNULL(@ParentId, 0) <> ISNULL(@OldParentId, 0)
    BEGIN
        DECLARE @OldPlace TABLE (Id INT NOT NULL PRIMARY KEY);
        DECLARE @NewPlace TABLE (Id INT NOT NULL PRIMARY KEY);
        DECLARE @Walk INT = @OldParentId, @Steps INT = 0;
        WHILE @Walk IS NOT NULL AND @Steps < 100      -- a cycle left by old data stops here
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM @OldPlace WHERE Id = @Walk) INSERT INTO @OldPlace (Id) VALUES (@Walk);
            SET @Walk = (SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Walk);
            SET @Steps += 1;
        END
        SELECT @Walk = @ParentId, @Steps = 0;
        WHILE @Walk IS NOT NULL AND @Steps < 100
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM @NewPlace WHERE Id = @Walk) INSERT INTO @NewPlace (Id) VALUES (@Walk);
            SET @Walk = (SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Walk);
            SET @Steps += 1;
        END

        INSERT INTO @AccessMoved (UserId, Gains)
        SELECT x.UserId, CAST(x.InNew AS BIT)
        FROM (SELECT uw.UserId,
                     InOld = MAX(CASE WHEN op.Id IS NOT NULL THEN 1 ELSE 0 END),
                     InNew = MAX(CASE WHEN np.Id IS NOT NULL THEN 1 ELSE 0 END)
              FROM security.UserWarehouses uw
              LEFT JOIN @OldPlace op ON op.Id = uw.WarehouseId
              LEFT JOIN @NewPlace np ON np.Id = uw.WarehouseId
              WHERE op.Id IS NOT NULL OR np.Id IS NOT NULL
              GROUP BY uw.UserId) x
        INNER JOIN security.Users u ON u.Id = x.UserId AND u.AllWarehouses = 0
        WHERE x.InOld <> x.InNew
          AND NOT EXISTS (SELECT 1 FROM security.UserWarehouses own WHERE own.UserId = x.UserId AND own.WarehouseId = @Id);

        -- the right that changes a user's warehouses (A12), held by an editor who may use every warehouse (a restricted
        -- editor could otherwise give himself any warehouse by moving it under one of his); no user (SSMS): allowed
        IF EXISTS (SELECT 1 FROM @AccessMoved) AND @UserId IS NOT NULL
           AND (security.fn_User_IsUnrestricted(@UserId) = 0 OR security.fn_UserHasPermission(@UserId, N'security.users.edit') = 0)
        BEGIN
            DECLARE @MoveMsg NVARCHAR(400) =
                N'Moving ' + @WarehouseCode + N' to another parent changes the warehouses '
                + CAST((SELECT COUNT(*) FROM @AccessMoved) AS NVARCHAR(10))
                + CASE WHEN (SELECT COUNT(*) FROM @AccessMoved) = 1 THEN N' user may use' ELSE N' users may use' END
                + N' (Users & Permissions ' + NCHAR(8250) + N' Users ' + NCHAR(8250) + N' Warehouses): ask an administrator.';
            THROW 50010, @MoveMsg, 1;
        END
    END

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
            AllowOutOfStockOverride = @AllowOutOfStockOverride,
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

        -- (92) the history of each user whose warehouses the move changed (W11): their ticks are the same, so the words
        --      are too, + " (LKS-01 moved under LUB)" for those who now have it, " (LKS-01 moved out of LUB)" (its old
        --      parent) for those who no longer have it
        IF EXISTS (SELECT 1 FROM @AccessMoved)
        BEGIN
            DECLARE @NewParentCode NVARCHAR(20) = (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ParentId);
            DECLARE @OldParentCode NVARCHAR(20) = (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @OldParentId);
            INSERT INTO security.UserWarehouseAudit (UserId, BeforeText, AfterText, ChangedBy)
            SELECT a.UserId, t.Txt,
                   CASE WHEN LEN(t.Txt) + LEN(sx.Suffix) <= 1000 THEN t.Txt + sx.Suffix
                        ELSE LEFT(t.Txt, 1000 - LEN(sx.Suffix)) + sx.Suffix END,
                   @UserId
            FROM @AccessMoved a
            CROSS APPLY (SELECT Txt = ISNULL(security.fn_User_WarehouseAccessText(a.UserId), N'Only: none')) t
            CROSS APPLY (SELECT Suffix = N' (' + @WarehouseCode
                                       + CASE WHEN a.Gains = 1 THEN N' moved under ' + ISNULL(@NewParentCode, N'another warehouse')
                                              ELSE N' moved out of ' + ISNULL(@OldParentCode, N'its parent') END + N')') sx;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

