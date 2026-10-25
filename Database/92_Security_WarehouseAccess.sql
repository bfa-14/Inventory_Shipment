SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 92: SECURITY - WAREHOUSE ACCESS PER USER (prompt 49)

   A user may be limited to some warehouses: where they may MOVE stock (post, cancel, reverse; name a warehouse on a
   draft; delete a draft), never what they may SEE. It changes nothing for anybody until an administrator restricts a
   user: every user, existing or new, keeps every warehouse.

     1. WHO. security.Users.AllWarehouses (default 1: every user before this script, and every new user) or "Only these
        warehouses", the ticks of security.UserWarehouses. A ticked PARENT GIVES ITS WHOLE TREE, worked out at check
        time, so a warehouse added under it later is included (A2). SYSTEM ADMINISTRATORS (an active role with IsSystem
        = 1) ALWAYS USE EVERY WAREHOUSE, whatever is stored (A3). On the way warehouses (script 90) are nobody's and never
        ticked: a transfer is checked on its From and its To (W12). "Only these" with none ticked: the user moves stock
        nowhere (A13). An inactive warehouse stays ticked (A14).
     2. ONE RULE, ONE SENTENCE, here in SQL: security.fn_User_CanUseWarehouse / fn_User_WarehouseRefusal - "You have no
        access to warehouse LKS-01: ask an administrator." ("warehouses LKS-01 and LUB-01"; more than three: "... and 2
        more"), error 50010 (HTTP 403, code WAREHOUSE_ACCESS) for every refusal. Looked up at each check, never cached,
        never in the token (M8): a change takes effect at once (W11). security.usp_User_GetAccess is NOT re-created.
     3. THE NET: an AFTER INSERT trigger on inventory.StockMovements (inventory.TR_StockMovements_WarehouseAccess) refuses
        any ledger row a restricted user writes into or out of a warehouse that is not theirs - every posting,
        cancellation, reversal, import, bulk action and automatic receipt, now and in families added later. Its FIRST
        statement leaves at once when no inserted row is a restricted user's, reading only the users who wrote the rows
        (a primary-key seek each, never a scan of security.Users). A trigger disabled by hand is enabled again at the
        next start. None of the big posting
        procedures is re-created (A4): the API checks the same rule early, for the readable answer before the click (W8).
     4. THE LEDGER WRITER RULE (W16, business-context 7.3): every INSERT INTO inventory.StockMovements stamps CreatedBy =
        the acting @UserId, never a value copied from another row, and never uses OUTPUT without INTO (error 334 once
        this trigger exists, which would stop Schema.sql at start-up). The trigger trusts CreatedBy; a row without a user
        (NULL) is never refused.
     5. TRANSFERS (W7, A9) carry the rule in inventory.fn_TransferOrder_Blocks (Seq 5, 50010): the From for what the
        source does (edit, delete, release, send for approval, withdraw, back to draft, Fill to Max, Add items below Min,
        dispatch, change a dispatch's ETA, reverse a dispatch, Nothing more will be sent, cancel; "Approve & release" of a
        draft), the To for receiving (receive, reverse a receipt, create a return), both for Dispatch and receive, either
        for the expected arrival, reference and notes; approving or rejecting a request sent by someone else needs no
        warehouse. Save refuses a From the editor may not use; the To of a new order may be any warehouse. The list gets
        the filter @Mine (From or to / From / To my warehouses) and the menu count the transfers on the way to the
        reader's warehouses (usp_TransferOrder_ToReceiveCount).
     6. STOCK LEVELS (W17, A20): viewing is never limited; setting, removing and importing a warehouse's Min / Max need
        that warehouse.
     7. THE WAREHOUSE LOOKUP answers CanUse for the reader (worked out per request), so the pickers offer the reader's
        warehouses only; the DELETE of an unused warehouse takes its ticks with it (cascade) and writes, for each user who
        had it, a history row "Only: LKS-01 (LKS-02 deleted)" (W13, A15). A tick is never "use" (fn_Warehouse_IsUsed is
        not changed). MOVING a warehouse to another parent changes who may use it (a ticked parent gives its whole
        tree): when it changes a restricted user's warehouses, only an editor who may use every warehouse and holds
        security.users.edit may move it (50010 otherwise), and each such user gets a history row "Only: LUB (LKS-01
        moved under LUB)".
     8. THE DIALOG (Users & Permissions > Users > Warehouses...): read, saved with the right security.users.edit (no new
        permission, A12), every change kept in security.UserWarehouseAudit (who, when, before -> after; W11). No row
        version: the last save wins and the history shows both (A11).

   Objects
     New column        security.Users.AllWarehouses (BIT NOT NULL, DF_Users_AllWarehouses DEFAULT 1: every existing row 1,
                       no data step)
     New tables        security.UserWarehouses (PK UserId, WarehouseId; both keys ON DELETE CASCADE),
                       security.UserWarehouseAudit
     New functions     security.fn_User_IsUnrestricted, fn_User_CanUseWarehouse, fn_User_Warehouses,
                       fn_User_WarehouseRefusal, fn_User_WarehouseAccessText
     New trigger       inventory.TR_StockMovements_WarehouseAccess (AFTER INSERT on inventory.StockMovements)
     New procedures    security.usp_User_WarehouseRefusal, usp_User_Warehouses_Get, usp_User_SetWarehouses,
                       usp_User_WarehouseSummaries; inventory.usp_TransferOrder_ToReceiveCount
     Re-created        masterdata.usp_Warehouse_Lookup             from the body of script 91: + @UserId (last), CanUse (last)
                       masterdata.usp_Warehouse_Delete             from the body of script 90: + @UserId (last), one history row
                                                                   per user who ticked the warehouse, in one transaction
                       masterdata.usp_Warehouse_Update             from the body of script 91: a move to another parent that
                                                                   changes users' warehouses needs an unrestricted editor with
                                                                   security.users.edit (50010), and writes their history
                       inventory.fn_TransferOrder_Blocks           from the body of script 91: + the access rows (Seq 5, 50010)
                       inventory.usp_TransferOrder_Save            from the body of script 90: the From named must be the editor's
                       inventory.usp_TransferOrder_Search          from the body of script 90: + @UserId, @Mine
                       inventory.usp_ItemWarehouseLevel_Set, _Remove, _ImportCheck, _Import
                                                                   from the body of script 91: a warehouse the user may not use
                                                                   is refused (Set, Remove) or an Error row (the import)

   Errors (block 50xxx, security): new 50010 no access to a warehouse (every family, the trigger, transfers, stock
   levels: HTTP 403, WAREHOUSE_ACCESS); new 50011 the Warehouses dialog was refused, and this script's guard (400,
   VALIDATION). Reused: 50003 user not found; 52003-52009 (the warehouse delete, unchanged); 62000 (the transfer list's
   filter).

   Not changed: security.usp_User_GetAccess (sign-in, refresh, me and the token), every permission and grant (no
   permission is added); inventory.usp_StockDocument_*, sales.usp_SalesDocument_*, purchase.usp_PurchaseDocument_*,
   purchase.usp_GoodsReceipt_*, logistics.usp_Container_*, the movement procedures (their bodies, messages and numbers;
   the trigger is the only thing under them); usp_TransferOrder_Get, _UpdateDetails, _Availability, the action
   procedures, usp_TransferPosting_SetEta / _Reverse, _FillToMax, _BelowMinCandidates, _CreateFromLevels (they read
   Blocks and Save); masterdata.fn_Warehouse_IsUsed (a tick is not use); every list, page, report, export and the
   Dashboard (viewing is never limited); purchase orders and supplier invoices (an invoice whose posting receives its
   goods is posted, and its receipt refused through its existing warning).

   Requires scripts 90 and 91 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up, and
   builds a brand-new empty database (the column and tables before every object that reads them; the trigger after the
   functions it calls).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'masterdata.Warehouses', N'IsTransit') IS NULL                          -- 90
   OR OBJECT_ID(N'inventory.fn_TransferOrder_Blocks', N'IF') IS NULL                    -- 90
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsUsedInTransactions', N'FN') IS NULL        -- 91
   OR OBJECT_ID(N'inventory.ItemWarehouseLevels', N'U') IS NULL                         -- 91
    THROW 50011, 'Script 92 requires scripts 90 and 91: apply them first.', 1;
GO

/* ================================================================== 2. The column */

IF COL_LENGTH(N'security.Users', N'AllWarehouses') IS NULL
BEGIN
    -- 1 = every warehouse, including those added later: every user before script 92, and every new user.
    ALTER TABLE security.Users ADD AllWarehouses BIT NOT NULL CONSTRAINT DF_Users_AllWarehouses DEFAULT (1);
    PRINT 'security.Users: added AllWarehouses (every existing user keeps every warehouse)';
END
GO

/* ================================================================== 3. The tables */

-- (92) THE WAREHOUSES A USER WITH "ONLY THESE WAREHOUSES" MAY USE: one row per tick, meaningful only while the user's
--      AllWarehouses = 0 (usp_User_SetWarehouses clears them when it is set back to 1). A ticked parent gives its whole
--      tree (worked out at check time). OWNED by the user and the warehouse: deleting either deletes its ticks (M5:
--      script 90's usp_Warehouse_IsReferenced skips cascading keys, so a tick never makes a warehouse undeletable). No
--      multiple cascade path: masterdata.Warehouses.CreatedBy / UpdatedBy are NO ACTION. GrantedBy has no key, as
--      security.UserRoles.AssignedBy.
IF OBJECT_ID(N'security.UserWarehouses', N'U') IS NULL
BEGIN
    CREATE TABLE security.UserWarehouses
    (
        UserId       INT          NOT NULL,
        WarehouseId  INT          NOT NULL,
        GrantedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_UserWarehouses_GrantedAtUtc DEFAULT (SYSUTCDATETIME()),
        GrantedBy    INT          NULL,   -- security.Users.Id of the administrator who ticked it (no FK, as UserRoles.AssignedBy)
        CONSTRAINT PK_UserWarehouses PRIMARY KEY CLUSTERED (UserId, WarehouseId),
        CONSTRAINT FK_UserWarehouses_Users      FOREIGN KEY (UserId)      REFERENCES security.Users (Id)        ON DELETE CASCADE,
        CONSTRAINT FK_UserWarehouses_Warehouses FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id) ON DELETE CASCADE
    );
    CREATE NONCLUSTERED INDEX IX_UserWarehouses_WarehouseId ON security.UserWarehouses (WarehouseId);
    PRINT 'Created security.UserWarehouses';
END
GO

-- (92) EVERY CHANGE OF A USER'S WAREHOUSES (W11): before -> after in words ("All warehouses", "Only: LKS-01, LUB",
--      "Only: none", + " (LKS-02 deleted)" when a ticked warehouse was deleted), who, when. ChangedBy has no key.
IF OBJECT_ID(N'security.UserWarehouseAudit', N'U') IS NULL
BEGIN
    CREATE TABLE security.UserWarehouseAudit
    (
        Id           BIGINT IDENTITY(1,1) NOT NULL,
        UserId       INT            NOT NULL,
        BeforeText   NVARCHAR(1000) NOT NULL,
        AfterText    NVARCHAR(1000) NOT NULL,
        ChangedBy    INT            NULL,   -- security.Users.Id (no FK)
        ChangedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_UserWarehouseAudit_ChangedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_UserWarehouseAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_UserWarehouseAudit_Users FOREIGN KEY (UserId) REFERENCES security.Users (Id) ON DELETE CASCADE
    );
    CREATE NONCLUSTERED INDEX IX_UserWarehouseAudit_User ON security.UserWarehouseAudit (UserId, ChangedAtUtc DESC);
    PRINT 'Created security.UserWarehouseAudit';
END
GO

/* ================================================================== 4. The rule: five functions */

-- (92) 1 = THE USER MAY USE EVERY WAREHOUSE: All warehouses, or an active system role (A3). NULL = no user: never
--      refused (rows older than the user stamp; every writer stamps the acting user, W16). An unknown id: 0. For a user
--      with All warehouses: one primary-key seek.
CREATE OR ALTER FUNCTION security.fn_User_IsUnrestricted (@UserId INT)
RETURNS BIT
AS
BEGIN
    IF @UserId IS NULL RETURN 1;
    IF EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId AND AllWarehouses = 1) RETURN 1;
    IF EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
               WHERE ur.UserId = @UserId AND r.IsSystem = 1 AND r.IsActive = 1) RETURN 1;
    RETURN 0;
END
GO

-- (92) 1 = THE USER MAY MOVE STOCK IN THIS WAREHOUSE: unrestricted, or the warehouse or one of its ancestors is ticked
--      (A2: a warehouse added under a ticked parent later is included). An On the way warehouse (90) is nobody's: 1 here,
--      a transfer being checked on its From and To (W12). NULL warehouse: 1 (nothing to refuse).
CREATE OR ALTER FUNCTION security.fn_User_CanUseWarehouse (@UserId INT, @WarehouseId INT)
RETURNS BIT
AS
BEGIN
    IF @WarehouseId IS NULL OR security.fn_User_IsUnrestricted(@UserId) = 1 RETURN 1;
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsTransit = 1) RETURN 1;
    DECLARE @Id INT = @WarehouseId, @Steps INT = 0;
    WHILE @Id IS NOT NULL AND @Steps < 100      -- a cycle left by old data stops here
    BEGIN
        IF EXISTS (SELECT 1 FROM security.UserWarehouses WHERE UserId = @UserId AND WarehouseId = @Id) RETURN 1;
        SET @Id = (SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Id);
        SET @Steps += 1;
    END
    RETURN 0;
END
GO

-- (92) EVERY WAREHOUSE THE USER'S TICKS GIVE, as a set: each ticked warehouse with everything under it
--      (masterdata.fn_Warehouse_Subtree), the lowest ticked id first, a warehouse reached twice kept once with the first
--      tick that gave it. Whatever AllWarehouses says: callers ask fn_User_IsUnrestricted first. Read by the warehouse
--      lookup (CanUse), the transfer list's filter, the to-receive count, the dialog's count.
CREATE OR ALTER FUNCTION security.fn_User_Warehouses (@UserId INT)
RETURNS @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY, GrantedWarehouseId INT NOT NULL)
AS
BEGIN
    DECLARE @Tick INT = (SELECT MIN(WarehouseId) FROM security.UserWarehouses WHERE UserId = @UserId);
    WHILE @Tick IS NOT NULL
    BEGIN
        INSERT INTO @Usable (WarehouseId, GrantedWarehouseId)
        SELECT s.Id, @Tick
        FROM masterdata.fn_Warehouse_Subtree(@Tick) s
        WHERE NOT EXISTS (SELECT 1 FROM @Usable u WHERE u.WarehouseId = s.Id);

        SET @Tick = (SELECT MIN(WarehouseId) FROM security.UserWarehouses WHERE UserId = @UserId AND WarehouseId > @Tick);
    END
    RETURN;
END
GO

-- (92) THE SENTENCE, the only place it is written: NULL when the user may use every warehouse of @WarehouseIds (a
--      comma-separated id list, as usp_User_SetRoles reads its roles), or is unrestricted; else "You have no access to
--      warehouse LKS-01: ask an administrator." / "... warehouses LKS-01 and LUB-01: ..." / "... warehouses KLW-01,
--      LKS-01 and LUB-01: ..." / "... warehouses KLW-01, LKS-01, LUB-01 and 2 more: ask an administrator." (codes
--      sorted). Ids that are not numbers or not warehouses are ignored: the families' own checks name them.
--      The rule is asked only of the warehouses named (each found by its id first, TOP (1) in an APPLY): with a plain
--      join the optimizer evaluated fn_User_CanUseWarehouse for EVERY warehouse of the table before joining (about 5
--      ms a call on 140 warehouses, against 0.1 ms), and the trigger calls this for every statement of a restricted
--      user.
CREATE OR ALTER FUNCTION security.fn_User_WarehouseRefusal (@UserId INT, @WarehouseIds NVARCHAR(MAX))
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @WarehouseIds IS NULL OR security.fn_User_IsUnrestricted(@UserId) = 1 RETURN NULL;
    DECLARE @Count INT, @C1 NVARCHAR(20), @C2 NVARCHAR(20), @C3 NVARCHAR(20);
    WITH refused AS
    (
        SELECT DISTINCT w.WarehouseCode
        FROM STRING_SPLIT(@WarehouseIds, N',') s
        CROSS APPLY (SELECT TOP (1) x.Id, x.WarehouseCode FROM masterdata.Warehouses x
                     WHERE x.Id = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)) w
        CROSS APPLY (SELECT CanUse = security.fn_User_CanUseWarehouse(@UserId, w.Id)) c
        WHERE c.CanUse = 0
    ),
    sorted AS
    (
        SELECT WarehouseCode, Rn = ROW_NUMBER() OVER (ORDER BY WarehouseCode), Cnt = COUNT(*) OVER ()
        FROM refused
    )
    SELECT @Count = MAX(Cnt),
           @C1 = MAX(CASE WHEN Rn = 1 THEN WarehouseCode END),
           @C2 = MAX(CASE WHEN Rn = 2 THEN WarehouseCode END),
           @C3 = MAX(CASE WHEN Rn = 3 THEN WarehouseCode END)
    FROM sorted;
    IF ISNULL(@Count, 0) = 0 RETURN NULL;
    RETURN N'You have no access to warehouse' + CASE WHEN @Count > 1 THEN N's' ELSE N'' END + N' '
         + CASE WHEN @Count = 1 THEN @C1
                WHEN @Count = 2 THEN @C1 + N' and ' + @C2
                WHEN @Count = 3 THEN @C1 + N', ' + @C2 + N' and ' + @C3
                ELSE @C1 + N', ' + @C2 + N', ' + @C3 + N' and ' + CAST(@Count - 3 AS NVARCHAR(10)) + N' more' END
         + N': ask an administrator.';
END
GO

-- (92) A USER'S WAREHOUSES IN WORDS, for the history: "All warehouses" (AllWarehouses = 1), else "Only: " + the ticked
--      codes sorted, comma-separated, or "Only: none"; at most 1,000 characters (the longest head that fits, then
--      " and {n} more"). NULL for an unknown user.
CREATE OR ALTER FUNCTION security.fn_User_WarehouseAccessText (@UserId INT)
RETURNS NVARCHAR(1000)
AS
BEGIN
    DECLARE @All BIT = (SELECT AllWarehouses FROM security.Users WHERE Id = @UserId);
    IF @All IS NULL RETURN NULL;
    IF @All = 1 RETURN N'All warehouses';

    DECLARE @Codes TABLE (Seq INT NOT NULL PRIMARY KEY, Code NVARCHAR(20) NOT NULL);
    INSERT INTO @Codes (Seq, Code)
    SELECT ROW_NUMBER() OVER (ORDER BY w.WarehouseCode), w.WarehouseCode
    FROM security.UserWarehouses uw
    INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId
    WHERE uw.UserId = @UserId;

    DECLARE @N INT = (SELECT COUNT(*) FROM @Codes);
    IF @N = 0 RETURN N'Only: none';

    DECLARE @Full NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(Code AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY Seq) FROM @Codes);
    IF LEN(@Full) + 6 <= 1000 RETURN N'Only: ' + @Full;

    -- the first K codes that fit with " and {N - K} more" ("Only: " is 6 characters, each ", " 2)
    DECLARE @K INT = (SELECT MAX(c.Seq)
                      FROM (SELECT Seq, Running = SUM(LEN(Code) + 2) OVER (ORDER BY Seq ROWS UNBOUNDED PRECEDING) - 2
                            FROM @Codes) c
                      WHERE 6 + c.Running + LEN(N' and ' + CAST(@N - c.Seq AS NVARCHAR(10)) + N' more') <= 1000);
    RETURN N'Only: ' + (SELECT STRING_AGG(Code, N', ') WITHIN GROUP (ORDER BY Seq) FROM @Codes WHERE Seq <= @K)
         + N' and ' + CAST(@N - @K AS NVARCHAR(10)) + N' more';
END
GO

/* ================================================================== 5. The net: the ledger trigger */

-- (92) THE NET UNDER EVERY DOCUMENT THAT MOVES STOCK. A restricted user (security.Users.AllWarehouses = 0, not a system
--      administrator) can never write a ledger row into or out of a warehouse that is not theirs, whatever wrote it: a
--      posting, a cancellation, a reversal, an import, a bulk action, the receipt an invoice makes when it is posted, a
--      family added later. It trusts CreatedBy, which every writer stamps with the acting user (W16). The first
--      statement leaves at once when no row is a restricted user's. A refusal aborts the statement and dooms the
--      writer's transaction; the writer's CATCH rethrows 50010 with this sentence (inside "Receive the goods now" it
--      becomes the invoice's warning). AFTER INSERT only (the one DELETE, script 31's, is untouched); it writes
--      nothing, so it never recurses and keeps the writer's @@ROWCOUNT and SCOPE_IDENTITY().
CREATE OR ALTER TRIGGER inventory.TR_StockMovements_WarehouseAccess
ON inventory.StockMovements
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    -- The first statement: leave when no inserted row is a restricted user's. It reads only the users who WROTE the
    -- rows, one primary-key seek per distinct CreatedBy (FORCESEEK), the row the foreign-key check on CreatedBy already
    -- reads: never a scan of security.Users, which under locking READ COMMITTED would make every posting wait for any
    -- open change to any user (a sign-in stamping LastLoginAtUtc, a role edit, the Warehouses dialog, an SSMS session).
    -- The writers below read the same way.
    IF NOT EXISTS (SELECT 1
                   FROM (SELECT DISTINCT CreatedBy FROM inserted WHERE CreatedBy IS NOT NULL) i
                   INNER JOIN security.Users u WITH (FORCESEEK) ON u.Id = i.CreatedBy
                   WHERE u.AllWarehouses = 0)
        RETURN;
    DECLARE @UserId INT, @Ids NVARCHAR(MAX), @Refusal NVARCHAR(400);
    SET @UserId = (SELECT MIN(i.CreatedBy)
                   FROM (SELECT DISTINCT CreatedBy FROM inserted WHERE CreatedBy IS NOT NULL) i
                   INNER JOIN security.Users u WITH (FORCESEEK) ON u.Id = i.CreatedBy
                   WHERE u.AllWarehouses = 0);
    WHILE @UserId IS NOT NULL
    BEGIN
        SET @Ids = (SELECT STRING_AGG(CAST(x.WarehouseId AS NVARCHAR(MAX)), N',')
                    FROM (SELECT DISTINCT WarehouseId FROM inserted WHERE CreatedBy = @UserId) x);
        SET @Refusal = security.fn_User_WarehouseRefusal(@UserId, @Ids);
        IF @Refusal IS NOT NULL THROW 50010, @Refusal, 1;
        SET @UserId = (SELECT MIN(i.CreatedBy)
                       FROM (SELECT DISTINCT CreatedBy FROM inserted WHERE CreatedBy > @UserId) i
                       INNER JOIN security.Users u WITH (FORCESEEK) ON u.Id = i.CreatedBy
                       WHERE u.AllWarehouses = 0);
    END
END
GO

-- (92) THE NET IS ALWAYS ON: CREATE OR ALTER keeps a trigger disabled by hand (DISABLE TRIGGER) disabled, so the next
--      start enables it again (Check 2).
IF EXISTS (SELECT 1 FROM sys.triggers WHERE object_id = OBJECT_ID(N'inventory.TR_StockMovements_WarehouseAccess') AND is_disabled = 1)
BEGIN
    ENABLE TRIGGER inventory.TR_StockMovements_WarehouseAccess ON inventory.StockMovements;
    PRINT 'inventory.TR_StockMovements_WarehouseAccess: enabled again (it had been disabled by hand)';
END
GO

/* ================================================================== 6. The security procedures */

-- (92) MAY THE USER USE THESE WAREHOUSES? (the API's early check, IWarehouseAccessService; read-only, no cache).
--      1: one row - IsUnrestricted (fn_User_IsUnrestricted), Message (the sentence for every id of @WarehouseIds the user
--         may not use, NULL when none).
--      2: one row per id the user may NOT use - WarehouseId, Message (its own one-warehouse sentence): the import's
--         per-row answer. Always returned; empty for an unrestricted user or without ids.
--      For an unrestricted user: one primary-key seek.
CREATE OR ALTER PROCEDURE security.usp_User_WarehouseRefusal
    @UserId       INT,
    @WarehouseIds NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Unrestricted BIT = security.fn_User_IsUnrestricted(@UserId);
    SET @WarehouseIds = NULLIF(LTRIM(RTRIM(@WarehouseIds)), N'');

    SELECT IsUnrestricted = @Unrestricted,
           Message        = CAST(CASE WHEN @Unrestricted = 1 OR @WarehouseIds IS NULL THEN NULL
                                      ELSE security.fn_User_WarehouseRefusal(@UserId, @WarehouseIds) END AS NVARCHAR(400));

    IF @Unrestricted = 1 OR @WarehouseIds IS NULL
        SELECT WarehouseId = CAST(NULL AS INT), Message = CAST(NULL AS NVARCHAR(400)) WHERE 1 = 0;
    ELSE
        -- each id found first, then the rule (see fn_User_WarehouseRefusal: never the rule for the whole table)
        SELECT x.WarehouseId,
               Message = CAST(security.fn_User_WarehouseRefusal(@UserId, CAST(x.WarehouseId AS NVARCHAR(12))) AS NVARCHAR(400))
        FROM (SELECT DISTINCT WarehouseId = w.Id
              FROM STRING_SPLIT(@WarehouseIds, N',') s
              CROSS APPLY (SELECT TOP (1) v.Id FROM masterdata.Warehouses v WHERE v.Id = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)) w) x
        CROSS APPLY (SELECT CanUse = security.fn_User_CanUseWarehouse(@UserId, x.WarehouseId)) c
        WHERE c.CanUse = 0
        ORDER BY x.WarehouseId;
END
GO

-- (92) THE "WAREHOUSES OF {user}" DIALOG.
--      1: UserId, Username, FullName, AllWarehouses, IsSystemAdministrator (an active system role: every warehouse,
--         whatever is stored). No user: 50003.
--      2: the ticks - WarehouseId, WarehouseCode, WarehouseName, BranchId, BranchCode, BranchName, IsActive, ChildCount,
--         GrantedAtUtc, GrantedByName ("-" when unknown), by code.
--      3: UsableCount - the warehouses the ticks give that hold stock (at the bottom of the tree, not On the way).
--      4: the history, the 100 newest - Id, BeforeText, AfterText, ChangedAtUtc, ChangedByName ("-" when unknown).
CREATE OR ALTER PROCEDURE security.usp_User_Warehouses_Get
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId)
        THROW 50003, 'User not found.', 1;

    SELECT u.Id AS UserId, u.Username, u.FullName, u.AllWarehouses,
           IsSystemAdministrator = CAST(CASE WHEN EXISTS (SELECT 1 FROM security.UserRoles ur
                                                          INNER JOIN security.Roles r ON r.Id = ur.RoleId
                                                          WHERE ur.UserId = u.Id AND r.IsSystem = 1 AND r.IsActive = 1)
                                             THEN 1 ELSE 0 END AS BIT)
    FROM security.Users u
    WHERE u.Id = @UserId;

    SELECT uw.WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.IsActive,
           ChildCount    = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           uw.GrantedAtUtc,
           GrantedByName = ISNULL(g.FullName, N'-')
    FROM security.UserWarehouses uw
    INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    LEFT  JOIN security.Users g        ON g.Id = uw.GrantedBy
    WHERE uw.UserId = @UserId
    ORDER BY w.WarehouseCode;

    SELECT UsableCount = COUNT(*)
    FROM security.fn_User_Warehouses(@UserId) x
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    WHERE w.IsTransit = 0
      AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id);

    SELECT TOP (100) a.Id, a.BeforeText, a.AfterText, a.ChangedAtUtc, ChangedByName = ISNULL(c.FullName, N'-')
    FROM security.UserWarehouseAudit a
    LEFT JOIN security.Users c ON c.Id = a.ChangedBy
    WHERE a.UserId = @UserId
    ORDER BY a.ChangedAtUtc DESC, a.Id DESC;
END
GO

-- (92) SAVE A USER'S WAREHOUSES (the dialog; the API asks security.users.edit). @AllWarehouses 1 = every warehouse (the
--      ticks are cleared); 0 = only @WarehouseIds (comma-separated; blanks ignored, duplicates once; none = moves stock
--      nowhere, A13). A ticked warehouse under another ticked one is dropped: the parent covers it. One history row
--      when the words change (two equal saves: one row). No row version (A11): the last save wins. No result set: the
--      API re-reads with usp_User_Warehouses_Get. 50011 the dialog's refusals; 50003 user not found.
CREATE OR ALTER PROCEDURE security.usp_User_SetWarehouses
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

-- (92) THE USERS LIST'S "WAREHOUSES" COLUMN, for every user at once (read like the roles of the list).
--      1: one row per tick of a user with "Only these warehouses" - UserId, WarehouseId, WarehouseCode, WarehouseName,
--         BranchCode, IsActive, ChildCount, by user and code.
--      2: one row per user - UserId, AllWarehouses, IsSystemAdministrator.
CREATE OR ALTER PROCEDURE security.usp_User_WarehouseSummaries
AS
BEGIN
    SET NOCOUNT ON;

    SELECT uw.UserId, uw.WarehouseId, w.WarehouseCode, w.WarehouseName, b.BranchCode, w.IsActive,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
    FROM security.UserWarehouses uw
    INNER JOIN security.Users u        ON u.Id = uw.UserId AND u.AllWarehouses = 0
    INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    ORDER BY uw.UserId, w.WarehouseCode;

    SELECT u.Id AS UserId, u.AllWarehouses,
           IsSystemAdministrator = CAST(CASE WHEN EXISTS (SELECT 1 FROM security.UserRoles ur
                                                          INNER JOIN security.Roles r ON r.Id = ur.RoleId
                                                          WHERE ur.UserId = u.Id AND r.IsSystem = 1 AND r.IsActive = 1)
                                             THEN 1 ELSE 0 END AS BIT)
    FROM security.Users u
    ORDER BY u.Id;
END
GO

/* ================================================================== 7. Master data procedures re-created (4.3.6) */

/* (91) THE WAREHOUSES A DROPDOWN OFFERS (script 90's rows and columns), + why one counts as used: by stock or a
   document (IsUsedInTransactions), by stock levels (HasStockLevels). IsUsed = either, as fn_Warehouse_IsUsed says; each
   test is worked out once a row (the parent picker labels a warehouse that has levels and nothing else). */
-- Re-created (91) from the body of script 90: + IsUsedInTransactions and HasStockLevels (the two last columns), IsUsed
-- from them (same rows, same values).
-- Re-created (92) from the body of script 91: + @UserId (last) and the column CanUse (last): may the reader move
-- stock in it (worked out per request, never cached). Rows, order and every other column unchanged; without
-- @UserId every row but an On the way one has CanUse = 1.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL,
    @IncludeTransit BIT = 0,  -- (90) 1 = the branches' On the way warehouses too
    @UserId     INT = NULL    -- (92) the reader
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Unrestricted BIT = security.fn_User_IsUnrestricted(@UserId);          -- (92)
    DECLARE @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF @Unrestricted = 0 INSERT INTO @Usable (WarehouseId) SELECT WarehouseId FROM security.fn_User_Warehouses(@UserId);
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName,
           w.IsMainWarehouse, w.IsActive, w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           IsUsed     = CAST(u.T | u.L AS BIT),                             -- (91) = fn_Warehouse_IsUsed, worked out once
           w.IsTransit,                                                    -- (90)
           IsUsedInTransactions = u.T,                                     -- (91) stock or a document names it
           HasStockLevels       = u.L,                                     -- (91) it has stock levels
           CanUse               = CAST(CASE WHEN w.IsTransit = 1 THEN 0
                                            WHEN @Unrestricted = 1 OR w.Id IN (SELECT WarehouseId FROM @Usable) THEN 1
                                            ELSE 0 END AS BIT)                 -- (92) the reader may move stock in it
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    CROSS APPLY (SELECT T = masterdata.fn_Warehouse_IsUsedInTransactions(w.Id),
                        L = CAST(CASE WHEN EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels lv WHERE lv.WarehouseId = w.Id)
                                      THEN 1 ELSE 0 END AS BIT)) u                                       -- (91)
    WHERE (@ActiveOnly = 0 OR w.IsActive = 1 OR w.Id = @IncludeId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (w.IsTransit = 0 OR @IncludeTransit = 1 OR w.Id = @IncludeId)   -- (90)
    ORDER BY w.IsMainWarehouse DESC, w.WarehouseName;
END
GO

-- Re-created (90) from the body of script 28: + an On the way warehouse is refused (52009: it is removed with its
-- branch); the generic reference scan moved to usp_Warehouse_IsReferenced (the same keys: none cascades), with today's
-- sentence.
-- Re-created (92) from the body of script 90: + @UserId (last); the users who ticked the warehouse get a history row
-- "Only: LKS-01 (LKS-02 deleted)" in the DELETE's transaction (W13, A15). The checks and their messages unchanged.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Delete
    @Id     INT,
    @UserId INT = NULL        -- (92) who deletes it (the history's ChangedBy)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- (92)

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    -- (90) THE BRANCH'S ON THE WAY WAREHOUSE is the system's: usp_Branch_Delete removes it with its branch.
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsTransit = 1)
    BEGIN
        DECLARE @TransitMsg NVARCHAR(400) = (SELECT w.WarehouseCode + N' is the On the way warehouse of ' + b.BranchCode + N': it is removed with its branch.'
                                             FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                             WHERE w.Id = @Id);
        THROW 52009, @TransitMsg, 1;
    END

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deleted. Designate another warehouse as the Main Warehouse first.', 1;

    /* Said before the generic reference scan below, which would otherwise report a warehouse with
       children as "contains inventory or is referenced by other records" - true, but not the thing
       the reader has to fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @Id)
        THROW 52003, 'This warehouse has warehouses standing under it. Move or delete them first.', 1;

    -- (90) the generic reference scan, held once (ParentId is handled above, in its own words)
    DECLARE @Referenced BIT = 0;
    EXEC masterdata.usp_Warehouse_IsReferenced @Id, @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 52003, 'This warehouse cannot be deleted because it contains inventory or is referenced by other records. You may deactivate the warehouse instead.', 1;

    -- (92) THE DELETE, in one transaction with the history of the users who had ticked the warehouse (W13, A15)
    DECLARE @Code NVARCHAR(20) = (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @Id);
    DECLARE @Suffix NVARCHAR(40) = N' (' + @Code + N' deleted)';
    DECLARE @Had TABLE (UserId INT NOT NULL PRIMARY KEY, BeforeText NVARCHAR(1000) NOT NULL);
    BEGIN TRY
        BEGIN TRANSACTION;
        -- (92) the users who ticked it, in words before the tick goes (a tick left on a user with All warehouses
        --      means nothing: no history row for it)
        INSERT INTO @Had (UserId, BeforeText)
        SELECT uw.UserId, security.fn_User_WarehouseAccessText(uw.UserId)
        FROM security.UserWarehouses uw WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN security.Users u ON u.Id = uw.UserId AND u.AllWarehouses = 0
        WHERE uw.WarehouseId = @Id;
        -- the ticks go first (the cascade would take them with the warehouse; deleted here so that the words after
        -- can be read), then one history row per user: the words without the code + " ({code} deleted)"
        DELETE FROM security.UserWarehouses WHERE WarehouseId = @Id;
        INSERT INTO security.UserWarehouseAudit (UserId, BeforeText, AfterText, ChangedBy)
        SELECT h.UserId, h.BeforeText,
               CASE WHEN LEN(t.AfterText) + LEN(@Suffix) <= 1000 THEN t.AfterText + @Suffix
                    ELSE LEFT(t.AfterText, 1000 - LEN(@Suffix)) + @Suffix END,
               @UserId
        FROM @Had h
        CROSS APPLY (SELECT AfterText = ISNULL(security.fn_User_WarehouseAccessText(h.UserId), N'Only: none')) t;

        DELETE FROM masterdata.Warehouses WHERE Id = @Id;   -- the cascades take 91's levels
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* (92) CHANGE A WAREHOUSE (script 91's rules), + moving it to another parent changes who may use it. */
-- Re-created (91) from the body of script 90: + the levels sentence of the used-parent refusal (52000) when the new
-- parent is used only through its stock levels (fn_Warehouse_IsUsedInTransactions = 0); otherwise today's sentence.
-- Re-created (92) from the body of script 91: + a move to another parent that changes the warehouses of users with "Only
-- these warehouses" (a ticked parent gives its whole tree, read at check time: A2) needs an editor who may use every
-- warehouse and holds security.users.edit (A12) - 50010 otherwise, so a restricted user can never give himself a
-- warehouse by moving it under one of his - and writes a history row for each of those users (W11), in the update's
-- transaction. Every other check, message and effect unchanged.
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


/* ================================================================== 8. Transfer objects (4.3.7) */

/* (91) WHY AN ACTION ON A TRANSFER ORDER CANNOT BE DONE NOW (script 90's rules, one row per failed rule; the first row
   of an action is its reason), + Fill to Max and Add items below Min (spec 3.3.3.6): a draft only (62010 while waiting
   for approval, 62005 released or cancelled), the TRO type on (62008), warehouses an order can hold (62000), lines for
   Fill (62009), and stock levels at To for an active item (62009). Read by usp_TransferOrder_FillToMax,
   _BelowMinCandidates and usp_TransferOrder_Get (CanFillToMax / CanAddBelowMin). Needs inventory.ItemWarehouseLevels
   (section 2). */
-- Re-created (91) from the body of script 90: + FillToMax, AddBelowMin (the Seq 1 list, the order's ToCode / HasLines /
-- HasToLevels, the rows 130-134).
-- Re-created (92) from the body of script 91: + the warehouse access rows (Seq 5, 50010, W7 / A9): the From for what
-- the source does, the To for receiving, both for Dispatch and receive, either for the details, neither for approving
-- a request someone sent; Reject gets no row. Get's Can{Action} / reasons and every action procedure follow without
-- being re-created. With @UserId NULL or an unrestricted user no access row is ever made.
CREATE OR ALTER FUNCTION inventory.fn_TransferOrder_Blocks (@Id INT, @UserId INT)
RETURNS TABLE
AS
RETURN
WITH o AS
(
    SELECT tro.Id, tro.Status,
           No             = ISNULL(tro.DocumentNumber, N'this transfer order'),
           s.DispatchedBase, s.ReceivedBase, s.ToDispatchBase, s.OnTheWayBase,
           NotSentOnBy    = CASE WHEN tro.NotSentAtUtc IS NOT NULL
                                 THEN N'on ' + CONVERT(NVARCHAR(10), CAST(tro.NotSentAtUtc AS DATE), 103) + N' by ' + ISNULL(nu.FullName, N'an unknown user') END,
           NeedsApproval  = ISNULL(tt.NeedsApproval, 0),
           ap.CanApprove,
           PostingCount   = pc.N,
           TroOff         = CASE WHEN ISNULL(tt.IsActive, 0) = 0
                                 THEN N'Transfer orders are switched off: the document type TRO is inactive (Configuration ' + NCHAR(8250) + N' Document Types).' END,
           TrdOff         = CASE WHEN ISNULL(td.IsActive, 0) = 0
                                 THEN N'Transfer dispatches are switched off: the document type TRD is inactive (Configuration ' + NCHAR(8250) + N' Document Types).' END,
           TrrOff         = CASE WHEN ISNULL(tr.IsActive, 0) = 0
                                 THEN N'Transfer receipts are switched off: the document type TRR is inactive (Configuration ' + NCHAR(8250) + N' Document Types).' END,
           NoApproval     = N'Transfer orders need no approval (Configuration ' + NCHAR(8250) + N' Document Types): release it.',
           NotApprover    = CASE WHEN ap.CanApprove = 0
                                 THEN N'You may not approve transfer orders: it takes the permission Approve Transfer Orders.' END,
           -- (91) Fill to Max / Add items below Min: To's code, the order's lines, the levels at To for active items
           ToCode         = ISNULL(tw.WarehouseCode, N'the destination'),
           HasLines       = CASE WHEN EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = tro.Id) THEN 1 ELSE 0 END,
           HasToLevels    = CASE WHEN EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels lv
                                              INNER JOIN inventory.Items li ON li.Id = lv.ItemId AND li.IsActive = 1
                                              WHERE lv.WarehouseId = tro.ToWarehouseId) THEN 1 ELSE 0 END,
           NoLines        = CASE WHEN NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = tro.Id)
                                 THEN N'The order has no lines. Add at least one item before releasing it.' END,
           InactiveLine   = CASE WHEN ia.LineNumber IS NOT NULL
                                 THEN N'Line ' + CAST(ia.LineNumber AS NVARCHAR(10)) + N': item ' + ia.ItemCode + N' is inactive.' END,
           WarehouseProblem = wp.Message,
           -- Dispatch: the order's warehouse rules, the To-inactive case in its own words (the goods could not be received)
           DispatchWarehouseProblem = CASE WHEN tw.IsActive = 0 AND wp.Message = N'Warehouse ' + tw.WarehouseCode + N' is inactive.'
                                           THEN N'The destination ' + tw.WarehouseCode + N' is inactive: goods sent to it could not be received. Activate it, or cancel the order.'
                                           ELSE wp.Message END,
           -- Receive: rules 3-5 of fn_TransferOrder_WarehouseProblem for To alone (From no longer matters once the
           -- goods have left it), the inactive case in its own words
           ReceiveWarehouseProblem = CASE WHEN tw.Id IS NULL THEN N'The warehouse was not found.'
                                          WHEN tw.IsTransit = 1
                                               THEN tw.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot be chosen.'
                                          WHEN tw.IsActive = 0
                                               THEN N'The destination ' + tw.WarehouseCode + N' is inactive: activate it to receive these goods.'
                                          WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = tw.Id)
                                               THEN N'Warehouse ' + tw.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END,
           -- Seq 86: every line still to dispatch has nothing on hand at From
           NoStockAtFrom  = CASE WHEN EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                                              WHERE l.TransferOrderId = tro.Id AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0)
                                  AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                                                  WHERE l.TransferOrderId = tro.Id AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                                    AND (SELECT SUM(m.QuantityBase) FROM inventory.StockMovements m
                                                         WHERE m.ItemId = l.ItemId AND m.WarehouseId = tro.FromWarehouseId) > 0)
                                 THEN fw.WarehouseCode + N' has none of the items still to dispatch.' END,
           -- every dispatch, reversed or not (Back to draft); the posted, not reversed ones (Cancel); the returns not cancelled
           DispatchList   = ISNULL(da.List, N'') + CASE WHEN da.N > 3 THEN N' and ' + CAST(da.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END,
           PostedDispatchList = ISNULL(dp.List, N'') + CASE WHEN dp.N > 3 THEN N' and ' + CAST(dp.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END,
           ReturnList     = ISNULL(rt.List, N'') + CASE WHEN rt.N > 3 THEN N' and ' + CAST(rt.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END,
           -- an item whose received pieces are not all on the returns not cancelled (usp_TransferOrder_CreateReturn's
           -- ReturnableBase > 0)
           HasReturnable  = CASE WHEN EXISTS (SELECT 1
                                              FROM (SELECT l.ItemId, Received = SUM(l.ReceivedBase)
                                                    FROM inventory.TransferOrderLines l
                                                    WHERE l.TransferOrderId = tro.Id
                                                    GROUP BY l.ItemId) r
                                              WHERE r.Received - ISNULL((SELECT SUM(rl.OrderedBase)
                                                                         FROM inventory.TransferOrderLines rl
                                                                         INNER JOIN inventory.TransferOrders ro ON ro.Id = rl.TransferOrderId
                                                                         WHERE ro.ReturnOfOrderId = tro.Id AND ro.Status <> 3 AND rl.ItemId = r.ItemId), 0) > 0)
                                 THEN 1 ELSE 0 END
    FROM inventory.TransferOrders tro
    CROSS APPLY inventory.fn_TransferOrder_State(tro.Id) s
    -- the approval right is the decision's own rule (business-context 4.3 rule 3): the only permission read here
    CROSS APPLY (SELECT CanApprove = security.fn_UserHasPermission(@UserId, N'inventory.transfers.approve')) ap
    LEFT JOIN security.Users nu          ON nu.Id = tro.NotSentBy
    LEFT JOIN masterdata.Warehouses fw   ON fw.Id = tro.FromWarehouseId
    LEFT JOIN masterdata.Warehouses tw   ON tw.Id = tro.ToWarehouseId
    LEFT JOIN inventory.DocumentTypes tt ON tt.Code = N'TRO'
    LEFT JOIN inventory.DocumentTypes td ON td.Code = N'TRD'
    LEFT JOIN inventory.DocumentTypes tr ON tr.Code = N'TRR'
    OUTER APPLY (SELECT TOP (1) Message FROM inventory.fn_TransferOrder_WarehouseProblem(tro.FromWarehouseId, tro.ToWarehouseId)) wp
    OUTER APPLY (SELECT TOP (1) l.LineNumber, i.ItemCode
                 FROM inventory.TransferOrderLines l
                 INNER JOIN inventory.Items i ON i.Id = l.ItemId
                 WHERE l.TransferOrderId = tro.Id AND i.IsActive = 0
                 ORDER BY l.LineNumber) ia
    CROSS APPLY (SELECT N = COUNT(*) FROM inventory.TransferPostings p WHERE p.TransferOrderId = tro.Id) pc
    CROSS APPLY (SELECT N = (SELECT COUNT(*) FROM inventory.TransferPostings p WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch'),
                        List = (SELECT STRING_AGG(x.DocumentNumber, N', ') WITHIN GROUP (ORDER BY x.PostedAtUtc, x.Id)
                                FROM (SELECT TOP (3) p.Id, p.DocumentNumber, p.PostedAtUtc FROM inventory.TransferPostings p
                                      WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch'
                                      ORDER BY p.PostedAtUtc, p.Id) x)) da
    CROSS APPLY (SELECT N = (SELECT COUNT(*) FROM inventory.TransferPostings p WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch' AND p.Status = 2),
                        List = (SELECT STRING_AGG(x.DocumentNumber, N', ') WITHIN GROUP (ORDER BY x.PostedAtUtc, x.Id)
                                FROM (SELECT TOP (3) p.Id, p.DocumentNumber, p.PostedAtUtc FROM inventory.TransferPostings p
                                      WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch' AND p.Status = 2
                                      ORDER BY p.PostedAtUtc, p.Id) x)) dp
    CROSS APPLY (SELECT N = (SELECT COUNT(*) FROM inventory.TransferOrders r WHERE r.ReturnOfOrderId = tro.Id AND r.Status <> 3),
                        List = (SELECT STRING_AGG(x.Number, N', ') WITHIN GROUP (ORDER BY x.Id)
                                FROM (SELECT TOP (3) r.Id, Number = ISNULL(r.DocumentNumber, N'a draft') FROM inventory.TransferOrders r
                                      WHERE r.ReturnOfOrderId = tro.Id AND r.Status <> 3
                                      ORDER BY r.Id) x)) rt
    WHERE tro.Id = @Id
)
SELECT Action = CAST(b.Action AS NVARCHAR(30)), Seq = CAST(b.Seq AS INT), ErrorNumber = CAST(b.ErrorNumber AS INT),
       Message = CAST(b.Message AS NVARCHAR(400))
FROM
(
    -- Seq 1: no order, every action
    SELECT a.Action, Seq = 1, ErrorNumber = 62006, Message = N'Transfer order not found.'
    FROM (VALUES (N'Edit'), (N'Delete'), (N'Release'), (N'SendForApproval'), (N'Approve'), (N'Reject'), (N'Withdraw'),
                 (N'BackToDraft'), (N'Dispatch'), (N'Receive'), (N'DispatchAndReceive'), (N'NothingMoreSent'), (N'Cancel'),
                 (N'CreateReturn'), (N'UpdateDetails'), (N'ChangeEta'), (N'ReverseDispatch'), (N'ReverseReceipt'),
                 (N'FillToMax'), (N'AddBelowMin')) a (Action)   -- (91) FillToMax, AddBelowMin
    WHERE NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id)

    UNION ALL
    SELECT r.Action, r.Seq, r.ErrorNumber, r.Message
    FROM o
    CROSS APPLY (VALUES
        -- Edit: a draft only
        (N'Edit', 10, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: withdraw it to change it.' END),
        (N'Edit', 11, 62005, CASE WHEN o.Status = 2 AND o.PostingCount = 0
                                  THEN o.No + N' is released: its lines, quantities and warehouses are locked. Use Back to draft' + NCHAR(8230) + N' to change them.' END),
        (N'Edit', 12, 62005, CASE WHEN o.Status = 2 AND o.PostingCount > 0
                                  THEN o.No + N' is released and has moved goods: its lines, quantities and warehouses can no longer change.' END),
        (N'Edit', 13, 62005, CASE WHEN o.Status = 3 THEN o.No + N' is cancelled.' END),
        -- Delete: a draft only
        (N'Delete', 20, 62005, CASE WHEN o.Status <> 1
                                    THEN N'Only a draft transfer order can be deleted. A released one is cancelled with Cancel order' + NCHAR(8230) END),
        -- Release
        (N'Release', 30, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: an approver approves it, or withdraw it and release it.' END),
        (N'Release', 31, 62010, CASE WHEN o.Status = 2 THEN o.No + N' is already released.' END),
        (N'Release', 32, 62010, CASE WHEN o.Status = 3 THEN o.No + N' is cancelled.' END),
        -- Release, Send for approval, Approve: what a released order needs
        (N'Release', 33, 62008, o.TroOff), (N'SendForApproval', 33, 62008, o.TroOff), (N'Approve', 33, 62008, o.TroOff),
        (N'Release', 34, 62009, o.NoLines), (N'SendForApproval', 34, 62009, o.NoLines), (N'Approve', 34, 62009, o.NoLines),
        (N'Release', 35, 62000, o.WarehouseProblem), (N'SendForApproval', 35, 62000, o.WarehouseProblem), (N'Approve', 35, 62000, o.WarehouseProblem),
        (N'Release', 36, 62000, o.InactiveLine), (N'SendForApproval', 36, 62000, o.InactiveLine), (N'Approve', 36, 62000, o.InactiveLine),
        (N'Release', 37, 62014, CASE WHEN o.NeedsApproval = 1 AND o.CanApprove = 0
                                     THEN o.No + N' needs approval before it is released: use Send for approval' + NCHAR(8230) END),
        -- Send for approval
        (N'SendForApproval', 40, 62010, CASE WHEN o.NeedsApproval = 0 THEN o.NoApproval END),
        (N'SendForApproval', 41, 62010, CASE o.Status WHEN 4 THEN N'This transfer order is already waiting for approval.'
                                                      WHEN 2 THEN o.No + N' is already released.'
                                                      WHEN 3 THEN o.No + N' is cancelled.' END),
        -- Approve (from Waiting; Approve & release from a draft while the switch is on). From Waiting it stays allowed
        -- after the switch is turned off: turning a switch never changes an order already waiting.
        (N'Approve', 50, 62015, o.NotApprover),
        (N'Approve', 51, 62010, CASE o.Status WHEN 2 THEN o.No + N' is already released.' WHEN 3 THEN o.No + N' is cancelled.' END),
        (N'Approve', 52, 62010, CASE WHEN o.Status = 1 AND o.NeedsApproval = 0 THEN o.NoApproval END),
        -- Reject, Withdraw
        (N'Reject', 60, 62015, o.NotApprover),
        (N'Reject', 61, 62010, CASE WHEN o.Status <> 4 THEN N'Only an order waiting for approval can be rejected.' END),
        (N'Withdraw', 61, 62010, CASE WHEN o.Status <> 4 THEN N'Only an order waiting for approval can be withdrawn.' END),
        -- Back to draft: a released order that has never posted anything, reversed or not (Save replaces the lines,
        -- and posting lines must never lose their order line)
        (N'BackToDraft', 70, 62010, CASE WHEN o.Status <> 2 THEN N'Only a released order can go back to draft.' END),
        (N'BackToDraft', 71, 62010, CASE WHEN o.PostingCount > 0
                                         THEN o.No + N' has dispatches (' + o.DispatchList + N'): an order that has moved goods cannot go back to draft. Use Nothing more will be sent'
                                              + NCHAR(8230) + N' or Cancel order' + NCHAR(8230) + N' instead.' END),
        -- Dispatch, Dispatch and receive
        (N'Dispatch', 80, 62010, CASE o.Status WHEN 1 THEN N'Release the order first: goods are dispatched from a released order.'
                                               WHEN 4 THEN N'This transfer order is waiting for approval.'
                                               WHEN 3 THEN o.No + N' is cancelled.' END),
        (N'DispatchAndReceive', 80, 62010, CASE o.Status WHEN 1 THEN N'Release the order first: goods are dispatched from a released order.'
                                                         WHEN 4 THEN N'This transfer order is waiting for approval.'
                                                         WHEN 3 THEN o.No + N' is cancelled.' END),
        (N'Dispatch', 81, 62010, CASE WHEN o.NotSentOnBy IS NOT NULL THEN N'Nothing more will be sent on ' + o.No + N' (closed ' + o.NotSentOnBy + N').' END),
        (N'DispatchAndReceive', 81, 62010, CASE WHEN o.NotSentOnBy IS NOT NULL THEN N'Nothing more will be sent on ' + o.No + N' (closed ' + o.NotSentOnBy + N').' END),
        (N'Dispatch', 82, 62009, CASE WHEN o.ToDispatchBase = 0 THEN N'Everything ordered is already dispatched.' END),
        (N'DispatchAndReceive', 82, 62009, CASE WHEN o.ToDispatchBase = 0 THEN N'Everything ordered is already dispatched.' END),
        (N'Dispatch', 83, 62008, o.TrdOff), (N'DispatchAndReceive', 83, 62008, o.TrdOff),
        (N'DispatchAndReceive', 84, 62008, o.TrrOff), (N'Receive', 84, 62008, o.TrrOff),
        (N'Dispatch', 85, 62000, o.DispatchWarehouseProblem), (N'DispatchAndReceive', 85, 62000, o.DispatchWarehouseProblem),
        (N'Dispatch', 86, 62007, o.NoStockAtFrom), (N'DispatchAndReceive', 86, 62007, o.NoStockAtFrom),
        -- Receive
        (N'Receive', 90, 62010, CASE o.Status WHEN 1 THEN N'Release the order first.'
                                              WHEN 3 THEN o.No + N' is cancelled.'
                                              WHEN 4 THEN N'This transfer order is waiting for approval.' END),
        (N'Receive', 91, 62009, CASE WHEN o.OnTheWayBase = 0
                                     THEN CASE WHEN o.DispatchedBase = 0 THEN N'Nothing is on the way: dispatch goods first.'
                                               ELSE N'Everything dispatched has arrived.' END END),
        (N'Receive', 92, 62000, o.ReceiveWarehouseProblem),
        -- Nothing more will be sent
        (N'NothingMoreSent', 100, 62010, CASE WHEN o.Status <> 2 THEN N'Only a released order can be closed.' END),
        (N'NothingMoreSent', 101, 62010, CASE WHEN o.NotSentOnBy IS NOT NULL THEN N'Nothing more will be sent on ' + o.No + N' already (' + o.NotSentOnBy + N').' END),
        (N'NothingMoreSent', 102, 62010, CASE WHEN o.DispatchedBase = 0
                                              THEN N'Nothing has been dispatched on ' + o.No + N': use Cancel order' + NCHAR(8230) + N' instead.' END),
        (N'NothingMoreSent', 103, 62009, CASE WHEN o.ToDispatchBase = 0 THEN N'Everything ordered is already dispatched.' END),
        -- Cancel order: released, nothing dispatched (a reversed dispatch counts as none)
        (N'Cancel', 110, 62010, CASE o.Status WHEN 1 THEN N'A draft is deleted, not cancelled: use Delete.'
                                              WHEN 4 THEN N'Withdraw the request for approval first.'
                                              WHEN 3 THEN o.No + N' is already cancelled.' END),
        (N'Cancel', 111, 62010, CASE WHEN o.DispatchedBase > 0
                                     THEN o.No + N' has dispatched goods (' + o.PostedDispatchList + N'): reverse them first, or use Nothing more will be sent.' END),
        -- Create return: something received that no return not cancelled takes back yet
        (N'CreateReturn', 120, 62010, CASE WHEN o.ReceivedBase = 0 THEN N'Nothing was received on ' + o.No + N': there is nothing to return.' END),
        (N'CreateReturn', 121, 62010, CASE WHEN o.ReceivedBase > 0 AND o.HasReturnable = 0
                                           THEN N'Everything received on ' + o.No + N' is already on its returns (' + o.ReturnList + N'): open them.' END),
        -- Update details (Expected arrival, Reference, Notes of an order that is no longer a draft)
        (N'UpdateDetails', 140, 62010, CASE WHEN o.Status = 1 THEN N'A draft is changed with Save.' END),
        (N'UpdateDetails', 141, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: withdraw it to change it.' END),
        -- (91) Fill to Max and Add items below Min: a draft, the TRO type on, fit warehouses, lines (Fill), levels at To
        (N'FillToMax',   130, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: withdraw it to change it.' END),
        (N'AddBelowMin', 130, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: withdraw it to change it.' END),
        (N'FillToMax',   130, 62005, CASE WHEN o.Status = 2 THEN o.No + N' is released: its quantities are locked. Fill to Max works on a draft.' END),
        (N'AddBelowMin', 130, 62005, CASE WHEN o.Status = 2 THEN o.No + N' is released: its quantities are locked. Fill to Max works on a draft.' END),
        (N'FillToMax',   130, 62005, CASE WHEN o.Status = 3 THEN o.No + N' is cancelled.' END),
        (N'AddBelowMin', 130, 62005, CASE WHEN o.Status = 3 THEN o.No + N' is cancelled.' END),
        (N'FillToMax',   131, 62008, o.TroOff), (N'AddBelowMin', 131, 62008, o.TroOff),
        (N'FillToMax',   132, 62000, o.WarehouseProblem), (N'AddBelowMin', 132, 62000, o.WarehouseProblem),
        (N'FillToMax',   133, 62009, CASE WHEN o.HasLines = 0
                                          THEN N'The order has no lines: add items, or use Add items below Min' + NCHAR(8230) + N'.' END),
        (N'FillToMax',   134, 62009, CASE WHEN o.HasToLevels = 0
                                          THEN o.ToCode + N' has no stock levels: set them on Item Definition (Stock levels per warehouse) or import them on Inventory '
                                               + NCHAR(8250) + N' Stock Levels.' END),
        (N'AddBelowMin', 134, 62009, CASE WHEN o.HasToLevels = 0
                                          THEN o.ToCode + N' has no stock levels: set them on Item Definition (Stock levels per warehouse) or import them on Inventory '
                                               + NCHAR(8250) + N' Stock Levels.' END)
    ) r (Action, Seq, ErrorNumber, Message)
    WHERE r.Message IS NOT NULL

    UNION ALL
    -- (92) WAREHOUSE ACCESS (W7): the source decides what the source does, the destination receives. Seq 5: after "not
    --      found", before every status reason (a reader who may not use the warehouse can do nothing about the order's
    --      state). The table alias is t: o is this function's CTE.
    SELECT a.Action, 5, 50010, r.Msg
    FROM inventory.TransferOrders t
    CROSS APPLY (SELECT Msg = security.fn_User_WarehouseRefusal(@UserId, CAST(t.FromWarehouseId AS NVARCHAR(12)))) r
    CROSS JOIN (VALUES (N'Edit'), (N'Delete'), (N'Release'), (N'SendForApproval'), (N'Withdraw'), (N'BackToDraft'),
                       (N'Dispatch'), (N'NothingMoreSent'), (N'Cancel'), (N'ChangeEta'), (N'ReverseDispatch'),
                       (N'FillToMax'), (N'AddBelowMin')) a (Action)
    WHERE t.Id = @Id AND r.Msg IS NOT NULL
    UNION ALL
    -- "Approve & release" of a draft is a release; approving a request someone sent (Status 4) needs no warehouse (A9)
    SELECT N'Approve', 5, 50010, r.Msg
    FROM inventory.TransferOrders t
    CROSS APPLY (SELECT Msg = security.fn_User_WarehouseRefusal(@UserId, CAST(t.FromWarehouseId AS NVARCHAR(12)))) r
    WHERE t.Id = @Id AND t.Status = 1 AND r.Msg IS NOT NULL
    UNION ALL
    SELECT a.Action, 5, 50010, r.Msg
    FROM inventory.TransferOrders t
    CROSS APPLY (SELECT Msg = security.fn_User_WarehouseRefusal(@UserId, CAST(t.ToWarehouseId AS NVARCHAR(12)))) r
    CROSS JOIN (VALUES (N'Receive'), (N'CreateReturn'), (N'ReverseReceipt')) a (Action)
    WHERE t.Id = @Id AND r.Msg IS NOT NULL
    UNION ALL
    -- both ends, one sentence ("warehouses LKS-01 and LUB-01" when neither is the reader's)
    SELECT N'DispatchAndReceive', 5, 50010, r.Msg
    FROM inventory.TransferOrders t
    CROSS APPLY (SELECT Msg = security.fn_User_WarehouseRefusal(@UserId, CONCAT(t.FromWarehouseId, N',', t.ToWarehouseId))) r
    WHERE t.Id = @Id AND r.Msg IS NOT NULL
    UNION ALL
    -- either end may change the expected arrival, the reference and the notes (the sentence names both: either would do)
    SELECT N'UpdateDetails', 5, 50010, security.fn_User_WarehouseRefusal(@UserId, CONCAT(t.FromWarehouseId, N',', t.ToWarehouseId))
    FROM inventory.TransferOrders t
    WHERE t.Id = @Id
      AND security.fn_User_CanUseWarehouse(@UserId, t.FromWarehouseId) = 0
      AND security.fn_User_CanUseWarehouse(@UserId, t.ToWarehouseId) = 0
) b;
GO

/* 13.4 SAVE A DRAFT: creates one, or replaces an existing draft, lines and all (the lines may be empty on a draft).
   The checks, in order (62000 unless said): the TRO type is active (62008); an existing order is still editable
   (Blocks, Edit: a draft); the order date (required, at most one day ahead: the reader's time zone); the warehouses
   (inventory.usp_TransferOrder_CheckWarehouses: the one place of those rules); Expected arrival not before the order
   date; each line by line number (item, active, its unit, Ordered above 0).
   The order's branch follows From at every save (D2); the NUMBER is given at the first save by From's branch when the
   TRO type numbers documents at their first save (NumberOnPost 0), else at release, and then keeps the branch it got.
   Each line keeps its unit's packing formula of the moment it is saved (Ordered in pcs never changes under it). No
   result set: @NewId = the order. */
-- Re-created (92) from the body of script 90: + the From the request names must be the editor's (W7), checked after
-- the warehouse rules and before the number is taken (a refusal creates nothing and uses no number); the To may be any
-- warehouse (A9). 91's usp_TransferOrder_CreateFromLevels saves through it.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Save
    @Id              INT            = NULL,
    @DocumentDate    DATE,
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ExpectedArrival DATE           = NULL,
    @ReferenceNo     NVARCHAR(100)  = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @Lines           inventory.tvp_TransferOrderLine READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @TypeId INT, @TypeActive BIT, @NumberOnPost BIT,
            @BranchId INT, @Number NVARCHAR(30), @LineCount INT, @Pcs INT,
            @Tomorrow DATE = DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE));

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NOT NULL
        BEGIN
            SELECT @Status = Status, @Number = DocumentNumber
            FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;
        END

        -- 1. The type: switched off, no order is saved (the sentence of Blocks Seq 33)
        SELECT @TypeId = Id, @TypeActive = IsActive, @NumberOnPost = NumberOnPost FROM inventory.DocumentTypes WHERE Code = N'TRO';
        IF @TypeId IS NULL THROW 62008, 'The document type TRO is missing: restart the API so that script 90 creates it.', 1;
        IF @TypeActive = 0
        BEGIN
            SET @Msg = N'Transfer orders are switched off: the document type TRO is inactive (Configuration ' + NCHAR(8250) + N' Document Types).';
            THROW 62008, @Msg, 1;
        END

        -- 2. An existing order: only a draft is saved (Blocks, Edit; an unknown id is its Seq 1, "not found")
        IF @Id IS NOT NULL
        BEGIN
            SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
            FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
            WHERE b.Action = N'Edit' AND b.Message IS NOT NULL
            ORDER BY b.Seq;
            IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
        END

        -- 3. The order date (one day of tolerance ahead: the reader's time zone)
        IF @DocumentDate IS NULL THROW 62000, 'Order date is required.', 1;
        IF @DocumentDate > @Tomorrow THROW 62000, 'The order date cannot be in the future.', 1;

        -- 4. From and To
        EXEC inventory.usp_TransferOrder_CheckWarehouses @FromWarehouseId, @ToWarehouseId;

        -- (92) 4b. The From the request names must be the editor's (an existing order's STORED From is Blocks' Edit, step 2);
        --      the To may be any warehouse (A9)
        SET @Msg = security.fn_User_WarehouseRefusal(@UserId, CAST(@FromWarehouseId AS NVARCHAR(12)));
        IF @Msg IS NOT NULL THROW 50010, @Msg, 1;

        -- 5. Expected arrival
        IF @ExpectedArrival < @DocumentDate THROW 62000, 'Expected arrival cannot be before the order date.', 1;

        -- 6. The lines, the first failing by line number
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
               CASE WHEN i.Id IS NULL       THEN N'item not found.'
                    WHEN i.IsActive = 0     THEN N'item ' + i.ItemCode + N' is inactive.'
                    WHEN iu.Id IS NULL      THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
                    WHEN l.Quantity <= 0    THEN N'Ordered must be a whole number above 0.'
                    ELSE N'Ordered is too large.' END        -- Ordered in pcs above an INT (never typed in practice)
        FROM @Lines l
        LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
        LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
        WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR l.Quantity <= 0
           OR CAST(l.Quantity AS BIGINT) * iu.PackingFormula > 2147483647
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
        -- the order's total in pcs is an INT too (lines each within it can add up past it)
        IF (SELECT SUM(CAST(l.Quantity AS BIGINT) * iu.PackingFormula) FROM @Lines l
            INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId) > 2147483647
            THROW 62000, 'The order is too large: its lines add up to more pieces than can be counted. Split it into several orders.', 1;

        -- The writes
        SELECT @BranchId = BranchId FROM masterdata.Warehouses WHERE Id = @FromWarehouseId;
        SELECT @LineCount = COUNT(*), @Pcs = ISNULL(SUM(l.Quantity * iu.PackingFormula), 0)
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

        IF @Id IS NULL
        BEGIN
            IF @NumberOnPost = 0
                EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @BranchId;

            INSERT INTO inventory.TransferOrders (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, FromWarehouseId, ToWarehouseId,
                                                  ExpectedArrival, ReferenceNo, Notes, Status, TotalLines, TotalOrderedBase, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @FromWarehouseId, @ToWarehouseId,
                    @ExpectedArrival, @ReferenceNo, @Notes, 1, @LineCount, @Pcs, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'Created', CASE WHEN @Number IS NOT NULL THEN N'Created as ' + @Number ELSE N'Created (numbered when released)' END, @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.TransferOrders
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, FromWarehouseId = @FromWarehouseId, ToWarehouseId = @ToWarehouseId,
                ExpectedArrival = @ExpectedArrival, ReferenceNo = @ReferenceNo, Notes = @Notes,
                TotalLines = @LineCount, TotalOrderedBase = @Pcs,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'Updated', CAST(@LineCount AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs', @UserId);
        END

        INSERT INTO inventory.TransferOrderLines (TransferOrderId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, iu.PackingFormula, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

        COMMIT TRANSACTION;
        SET @NewId = @Id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.1 THE LIST, paged, and a totals row (2 result sets).
   Filters: @Search (the order's number, its reference, From's or To's code or name, the code of an item on one of its
   lines, the number of one of its dispatches or receipts); @Status = a shown status (Draft, PendingApproval, Released,
   PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled) or Open (released, neither Received nor
   Closed); @BranchId = From's OR To's branch (a transfer concerns both); From, To; @OnTheWayOnly (pieces on the way),
   @LateOnly (Late, worked out on the server in UTC), @WaitingForApproval (stored status 4: the approvers' list, the
   menu count's); the order date; @ItemId (an order with a line of the item).
   Sort: DocumentNumber | DocumentDate | FromWarehouse | ToWarehouse | Status (in the order of the shown statuses) |
   OrderedBase | OnTheWayBase | ExpectedArrival | CreatedAtUtc.
   1: one row per order (TotalCount = all pages): its figures, shown status and Late from fn_TransferOrder_State, the
      one place they are worked out.
   2: over every order of the filter (all pages): Orders, OnTheWayBase, LateOrders, WaitingForApproval. */
-- Re-created (92) from the body of script 90: + @UserId, @Mine (From or to / From / To the reader's warehouses: Any |
-- From | To, any case; NULL = no filter; an unrestricted reader is never filtered). Result sets unchanged.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Search
    @Search             NVARCHAR(100) = NULL,
    @Status             NVARCHAR(20)  = NULL,
    @BranchId           INT           = NULL,
    @FromWarehouseId    INT           = NULL,
    @ToWarehouseId      INT           = NULL,
    @OnTheWayOnly       BIT           = 0,
    @LateOnly           BIT           = 0,
    @WaitingForApproval BIT           = 0,
    @DateFrom           DATE          = NULL,
    @DateTo             DATE          = NULL,
    @ItemId             INT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'DocumentDate',
    @SortDirection      NVARCHAR(4)   = N'DESC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 25,
    @UserId             INT           = NULL,   -- (92) the reader
    @Mine               NVARCHAR(4)   = NULL    -- (92) Any | From | To the reader's warehouses; NULL = no filter
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    IF @Status IS NOT NULL AND @Status NOT IN (N'Draft', N'PendingApproval', N'Released', N'PartlyDispatched', N'Dispatched',
                                               N'PartlyReceived', N'Received', N'Closed', N'Cancelled', N'Open')
        THROW 62000, 'The status filter is Draft, PendingApproval, Released, PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled or Open.', 1;
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'FromWarehouse', N'ToWarehouse', N'Status',
                                                  N'OrderedBase', N'OnTheWayBase', N'ExpectedArrival', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    SELECT @OnTheWayOnly = ISNULL(@OnTheWayOnly, 0), @LateOnly = ISNULL(@LateOnly, 0), @WaitingForApproval = ISNULL(@WaitingForApproval, 0);

    -- (92) the reader's warehouses (W15): a restricted reader's list starts on "From or to my warehouses"
    SET @Mine = NULLIF(LTRIM(RTRIM(@Mine)), N'');
    IF @Mine IS NOT NULL AND @Mine NOT IN (N'Any', N'From', N'To')
        THROW 62000, 'Unknown warehouse filter: choose any, from or to.', 1;
    DECLARE @MineUnrestricted BIT = security.fn_User_IsUnrestricted(@UserId);
    DECLARE @MineIds TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF @Mine IS NOT NULL AND @MineUnrestricted = 0
        INSERT INTO @MineIds (WarehouseId) SELECT WarehouseId FROM security.fn_User_Warehouses(@UserId);

    -- THE FILTER ONCE, with each order's state: the shown status, Late and On the way are filters, so the state is
    -- worked out before the page, and the page and the totals both read it from here.
    DECLARE @Ids TABLE
    (
        Id             INT          NOT NULL PRIMARY KEY,
        StoredStatus   TINYINT      NOT NULL,
        DisplayStatus  NVARCHAR(20) NULL,
        StatusRank     INT          NOT NULL,
        IsLate         BIT          NOT NULL,
        ItemCount      INT          NOT NULL,
        OrderedBase    INT          NOT NULL,
        DispatchedBase INT          NOT NULL,
        ReceivedBase   INT          NOT NULL,
        OnTheWayBase   INT          NOT NULL,
        ToDispatchBase INT          NOT NULL,
        NotSentBase    INT          NOT NULL,
        LostBase       INT          NOT NULL
    );
    INSERT INTO @Ids (Id, StoredStatus, DisplayStatus, StatusRank, IsLate, ItemCount, OrderedBase, DispatchedBase, ReceivedBase,
                      OnTheWayBase, ToDispatchBase, NotSentBase, LostBase)
    SELECT o.Id, o.Status, st.DisplayStatus,
           CASE st.DisplayStatus WHEN N'Draft' THEN 1 WHEN N'PendingApproval' THEN 2 WHEN N'Released' THEN 3
                                 WHEN N'PartlyDispatched' THEN 4 WHEN N'Dispatched' THEN 5 WHEN N'PartlyReceived' THEN 6
                                 WHEN N'Received' THEN 7 WHEN N'Closed' THEN 8 ELSE 9 END,
           CAST(ISNULL(st.IsLate, 0) AS BIT), ISNULL(st.ItemCount, 0), ISNULL(st.OrderedBase, 0), ISNULL(st.DispatchedBase, 0),
           ISNULL(st.ReceivedBase, 0), ISNULL(st.OnTheWayBase, 0), ISNULL(st.ToDispatchBase, 0), ISNULL(st.NotSentBase, 0),
           ISNULL(st.LostBase, 0)
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    OUTER APPLY inventory.fn_TransferOrder_State(o.Id) st
    WHERE (@BranchId IS NULL OR fw.BranchId = @BranchId OR tw.BranchId = @BranchId)
      AND (@FromWarehouseId IS NULL OR o.FromWarehouseId = @FromWarehouseId)
      AND (@ToWarehouseId IS NULL OR o.ToWarehouseId = @ToWarehouseId)
      AND (@DateFrom IS NULL OR o.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR o.DocumentDate <= @DateTo)
      AND (@WaitingForApproval = 0 OR o.Status = 4)
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = o.Id AND l.ItemId = @ItemId))
      AND (@Mine IS NULL OR @MineUnrestricted = 1                                                          -- (92)
           OR (@Mine IN (N'Any', N'From') AND o.FromWarehouseId IN (SELECT WarehouseId FROM @MineIds))
           OR (@Mine IN (N'Any', N'To')   AND o.ToWarehouseId   IN (SELECT WarehouseId FROM @MineIds)))
      AND (@Status IS NULL
           OR (@Status = N'Open' AND o.Status = 2 AND ISNULL(st.DisplayStatus, N'') NOT IN (N'Received', N'Closed'))
           OR st.DisplayStatus = @Status)
      AND (@OnTheWayOnly = 0 OR st.OnTheWayBase > 0)
      AND (@LateOnly = 0 OR st.IsLate = 1)
      AND (@Search IS NULL
           OR o.DocumentNumber LIKE N'%' + @Search + N'%' OR o.ReferenceNo LIKE N'%' + @Search + N'%'
           OR fw.WarehouseCode LIKE N'%' + @Search + N'%' OR fw.WarehouseName LIKE N'%' + @Search + N'%'
           OR tw.WarehouseCode LIKE N'%' + @Search + N'%' OR tw.WarehouseName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                      INNER JOIN inventory.Items i ON i.Id = l.ItemId
                      WHERE l.TransferOrderId = o.Id AND i.ItemCode LIKE N'%' + @Search + N'%')
           OR EXISTS (SELECT 1 FROM inventory.TransferPostings p
                      WHERE p.TransferOrderId = o.Id AND p.DocumentNumber LIKE N'%' + @Search + N'%'));

    -- 1: the page
    SELECT o.Id, o.DocumentNumber, o.DocumentDate, o.BranchId, b.BranchCode,
           o.FromWarehouseId, FromWarehouseCode = fw.WarehouseCode, FromWarehouseName = fw.WarehouseName, FromBranchCode = fb.BranchCode,
           o.ToWarehouseId, ToWarehouseCode = tw.WarehouseCode, ToWarehouseName = tw.WarehouseName, ToBranchCode = tb.BranchCode,
           StatusCode = CASE o.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           x.DisplayStatus, x.IsLate, x.ItemCount, x.OrderedBase, x.DispatchedBase, x.ReceivedBase, x.OnTheWayBase,
           x.ToDispatchBase, x.NotSentBase, x.LostBase,
           o.ExpectedArrival, o.ReferenceNo, o.ReturnOfOrderId, ReturnOfNumber = ro.DocumentNumber,
           o.CreatedAtUtc, CreatedByName = cu.FullName,
           COUNT(*) OVER () AS TotalCount
    FROM @Ids x
    INNER JOIN inventory.TransferOrders o   ON o.Id = x.Id
    INNER JOIN masterdata.Branches b        ON b.Id = o.BranchId
    INNER JOIN masterdata.Warehouses fw     ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Branches fb       ON fb.Id = fw.BranchId
    INNER JOIN masterdata.Warehouses tw     ON tw.Id = o.ToWarehouseId
    INNER JOIN masterdata.Branches tb       ON tb.Id = tw.BranchId
    LEFT  JOIN inventory.TransferOrders ro  ON ro.Id = o.ReturnOfOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = o.CreatedBy
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN o.DocumentNumber WHEN N'FromWarehouse' THEN fw.WarehouseCode
                             WHEN N'ToWarehouse' THEN tw.WarehouseCode END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN o.DocumentNumber WHEN N'FromWarehouse' THEN fw.WarehouseCode
                             WHEN N'ToWarehouse' THEN tw.WarehouseCode END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN o.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN o.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN x.StatusRank END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN x.StatusRank END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OrderedBase' THEN x.OrderedBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OrderedBase' THEN x.OrderedBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnTheWayBase' THEN x.OnTheWayBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnTheWayBase' THEN x.OnTheWayBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ExpectedArrival' THEN o.ExpectedArrival END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ExpectedArrival' THEN o.ExpectedArrival END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN o.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN o.CreatedAtUtc END DESC,
        o.DocumentDate DESC, o.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- 2: totals over the whole filter (the list's summary row)
    SELECT Orders             = COUNT(*),
           OnTheWayBase       = ISNULL(SUM(x.OnTheWayBase), 0),
           LateOrders         = ISNULL(SUM(CASE WHEN x.IsLate = 1 THEN 1 ELSE 0 END), 0),
           WaitingForApproval = ISNULL(SUM(CASE WHEN x.StoredStatus = 4 THEN 1 ELSE 0 END), 0)
    FROM @Ids x;
END
GO

-- (92) THE TRANSFERS ON THE WAY TO THE READER'S WAREHOUSES (the menu count, A19; FB section 6): released orders (stored
--      status 2) whose To is one of the reader's warehouses and that have pieces on the way. 0 at once for an
--      unrestricted reader (whose count is the approvals' alone). Read-only, one row: ToReceive.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_ToReceiveCount
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF security.fn_User_IsUnrestricted(@UserId) = 1
    BEGIN
        SELECT ToReceive = 0;
        RETURN;
    END

    DECLARE @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    INSERT INTO @Usable (WarehouseId) SELECT WarehouseId FROM security.fn_User_Warehouses(@UserId);

    -- the released orders to those warehouses first; the state (counters) only for them
    DECLARE @Orders TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Orders (Id)
    SELECT o.Id FROM inventory.TransferOrders o
    WHERE o.Status = 2 AND o.ToWarehouseId IN (SELECT WarehouseId FROM @Usable);

    SELECT ToReceive = COUNT(*)
    FROM @Orders x
    CROSS APPLY inventory.fn_TransferOrder_State(x.Id) s
    WHERE s.OnTheWayBase > 0;
END
GO

/* ================================================================== 9. Stock level procedures re-created (4.3.8, A20) */

/* (91) SET AN ITEM'S LEVELS IN ONE OR MORE WAREHOUSES (Item Definition's card, Stock Levels), all or nothing. The checks,
   the first failing row by warehouse code (56000): the warehouse exists, is not On the way, has no warehouses under
   it, is active (a new or changed level only: L6), Min is a whole number 0 or more, Min and Max are at most
   1,000,000,000 pcs, Max is not below Min. Then, in the transaction, each row sent with a RowVersion is compared with
   the level as it stands, read WITH (UPDLOCK, HOLDLOCK) (56004: removed / changed by another user); a row without one
   is a NEW level: when somebody else has set one there meanwhile with another Min or Max, 56004 "... was added by
   another user" - never a silent overwrite.
   An unchanged row is neither rewritten nor audited. @Source ItemCard | StockLevels (anything else: ItemCard). No
   result set. */
-- Re-created (92) from the body of script 91: + a warehouse the user may not use is refused (50010, W17), after the
-- per-row tests, one sentence for every such warehouse of the request (an unchanged row of one too: the request names it).
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_Set
    @ItemId INT,
    @Levels inventory.tvp_ItemWarehouseLevel READONLY,
    @Source NVARCHAR(20) = N'ItemCard',
    @UserId INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Source IS NULL OR @Source NOT IN (N'ItemCard', N'StockLevels') SET @Source = N'ItemCard';

    DECLARE @ItemCode NVARCHAR(30), @Msg NVARCHAR(400);

    SELECT @ItemCode = ItemCode FROM inventory.Items WHERE Id = @ItemId;
    IF @ItemCode IS NULL THROW 56006, 'Item not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Levels) THROW 56000, 'Choose at least one warehouse.', 1;

    -- The first failing row, by warehouse code (a warehouse not found first)
    SELECT TOP (1) @Msg = m.Message
    FROM @Levels l
    LEFT JOIN masterdata.Warehouses w          ON w.Id = l.WarehouseId
    LEFT JOIN inventory.ItemWarehouseLevels cur ON cur.ItemId = @ItemId AND cur.WarehouseId = l.WarehouseId
    CROSS APPLY (SELECT Message = CASE
            WHEN w.Id IS NULL THEN N'A warehouse was not found.'
            WHEN w.IsTransit = 1
                THEN w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot have stock levels.'
            WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
                THEN N'Warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
            WHEN w.IsActive = 0
                 AND NOT (cur.ItemId IS NOT NULL AND cur.MinQuantityBase = l.MinQuantityBase
                          AND ISNULL(cur.MaxQuantityBase, -1) = ISNULL(l.MaxQuantityBase, -1))
                THEN N'Warehouse ' + w.WarehouseCode + N' is inactive: activate it to change its levels.'
            WHEN l.MinQuantityBase IS NULL OR l.MinQuantityBase < 0
                THEN w.WarehouseCode + N': Min must be a whole number, 0 or more.'
            WHEN l.MinQuantityBase > 1000000000 OR l.MaxQuantityBase > 1000000000
                THEN w.WarehouseCode + N': Min and Max can be at most 1,000,000,000 pcs.'
            WHEN l.MaxQuantityBase < l.MinQuantityBase
                THEN w.WarehouseCode + N': Max cannot be less than Min.' END) m
    WHERE m.Message IS NOT NULL
    ORDER BY w.WarehouseCode;
    IF @Msg IS NOT NULL THROW 56000, @Msg, 1;

    -- (92) every warehouse of the request must be the user's (one sentence for all of them)
    SET @Msg = security.fn_User_WarehouseRefusal(@UserId, (SELECT STRING_AGG(CAST(WarehouseId AS NVARCHAR(12)), N',') FROM @Levels));
    IF @Msg IS NOT NULL THROW 50010, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- The levels as they stand, locked until the commit
        DECLARE @Cur TABLE (WarehouseId INT NOT NULL PRIMARY KEY, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL, RowVersion BINARY(8) NOT NULL);
        INSERT INTO @Cur (WarehouseId, MinQuantityBase, MaxQuantityBase, RowVersion)
        SELECT lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase, lv.RowVersion
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        WHERE lv.ItemId = @ItemId AND lv.WarehouseId IN (SELECT l.WarehouseId FROM @Levels l);

        -- Somebody else removed or changed a level the page read, or added one where the page read none - a row sent
        -- without a RowVersion is a NEW level: it never replaces one somebody else has just set (unless it is the same
        -- Min and Max, which loses nothing). The first by warehouse code.
        SELECT TOP (1) @Msg = N'The stock level of ' + @ItemCode + N' at ' + w.WarehouseCode
                              + CASE WHEN l.RowVersion IS NULL     THEN N' was added by another user. Reload and try again.'
                                     WHEN c.WarehouseId IS NULL    THEN N' was removed by another user. Reload and try again.'
                                     ELSE N' was changed by another user. Reload and try again.' END
        FROM @Levels l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        LEFT  JOIN @Cur c ON c.WarehouseId = l.WarehouseId
        WHERE (l.RowVersion IS NOT NULL AND (c.WarehouseId IS NULL OR c.RowVersion <> l.RowVersion))
           OR (l.RowVersion IS NULL AND c.WarehouseId IS NOT NULL
               AND (c.MinQuantityBase <> l.MinQuantityBase OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(l.MaxQuantityBase, -1)))
        ORDER BY w.WarehouseCode;
        IF @Msg IS NOT NULL THROW 56004, @Msg, 1;

        -- The audit of each row that differs
        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, UserId)
        SELECT @ItemId, l.WarehouseId, CASE WHEN c.WarehouseId IS NULL THEN N'Added' ELSE N'Changed' END,
               c.MinQuantityBase, c.MaxQuantityBase, l.MinQuantityBase, l.MaxQuantityBase, @Source, @UserId
        FROM @Levels l
        LEFT JOIN @Cur c ON c.WarehouseId = l.WarehouseId
        WHERE c.WarehouseId IS NULL
           OR c.MinQuantityBase <> l.MinQuantityBase
           OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(l.MaxQuantityBase, -1);

        MERGE inventory.ItemWarehouseLevels WITH (HOLDLOCK) AS t
        USING (SELECT l.WarehouseId, l.MinQuantityBase, l.MaxQuantityBase FROM @Levels l) AS s
        ON t.ItemId = @ItemId AND t.WarehouseId = s.WarehouseId
        WHEN MATCHED AND (t.MinQuantityBase <> s.MinQuantityBase OR ISNULL(t.MaxQuantityBase, -1) <> ISNULL(s.MaxQuantityBase, -1)) THEN
            UPDATE SET MinQuantityBase = s.MinQuantityBase, MaxQuantityBase = s.MaxQuantityBase,
                       UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase, CreatedBy, UpdatedBy)
            VALUES (@ItemId, s.WarehouseId, s.MinQuantityBase, s.MaxQuantityBase, @UserId, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* (91) REMOVE ONE LEVEL (allowed on an inactive warehouse, L6): the row WITH (UPDLOCK, HOLDLOCK); gone 56006, changed
   since the page read it 56004; audit Removed; DELETE. @Source ItemCard | StockLevels (anything else: ItemCard). */
-- Re-created (92) from the body of script 91: + a warehouse the user may not use is refused (50010, W17), after "This
-- stock level no longer exists".
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_Remove
    @ItemId      INT,
    @WarehouseId INT,
    @RowVersion  BINARY(8)    = NULL,
    @Source      NVARCHAR(20) = N'ItemCard',
    @UserId      INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Source IS NULL OR @Source NOT IN (N'ItemCard', N'StockLevels') SET @Source = N'ItemCard';

    DECLARE @Min INT, @Max INT, @Rv BINARY(8), @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Min = lv.MinQuantityBase, @Max = lv.MaxQuantityBase, @Rv = lv.RowVersion
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        WHERE lv.ItemId = @ItemId AND lv.WarehouseId = @WarehouseId;

        IF @Rv IS NULL THROW 56006, 'This stock level no longer exists. Reload the page.', 1;

        -- (92) the warehouse must be the user's
        SET @Msg = security.fn_User_WarehouseRefusal(@UserId, CAST(@WarehouseId AS NVARCHAR(12)));
        IF @Msg IS NOT NULL THROW 50010, @Msg, 1;

        IF @RowVersion IS NOT NULL AND @RowVersion <> @Rv
        BEGIN
            SET @Msg = N'The stock level of ' + ISNULL((SELECT ItemCode FROM inventory.Items WHERE Id = @ItemId), N'the item')
                     + N' at ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId), N'the warehouse')
                     + N' was changed by another user. Reload and try again.';
            THROW 56004, @Msg, 1;
        END

        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, UserId)
        VALUES (@ItemId, @WarehouseId, N'Removed', @Min, @Max, NULL, NULL, @Source, @UserId);

        DELETE FROM inventory.ItemWarehouseLevels WHERE ItemId = @ItemId AND WarehouseId = @WarehouseId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- (91) THE IMPORT'S CHECK STEP: the judgement of every row (inventory.fn_ItemWarehouseLevel_ImportJudge), nothing
--      written. @UserId is read by script 92 (warehouse access).
-- Re-created (92) from the body of script 91: + a row in a warehouse the user may not use is an Error with the
-- sentence (W6, W17): the judgement goes into #j (the same 20 columns), the refused Valid / Warning rows become Error /
-- None, then the same 20 columns by row number. (SELECT ... INTO types Status / Action / Message from the function:
-- NVARCHAR(10), (10), (500); 'Error', 'None' and the sentence fit.)
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_ImportCheck
    @Rows   inventory.tvp_ItemWarehouseLevelImport READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemInput, j.ItemId, j.ItemCode, j.ItemName, j.ItemIsActive,
           j.WarehouseInput, j.WarehouseId, j.WarehouseCode, j.WarehouseName, j.BranchCode,
           j.MinQuantityBase, j.MaxQuantityBase, j.IsRemove, j.HasLevel, j.CurrentMinBase, j.CurrentMaxBase
    INTO #j
    FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j;

    -- (92) the rows a restricted user may not import: Error, with the sentence (one call per warehouse)
    IF security.fn_User_IsUnrestricted(@UserId) = 0
    BEGIN
        DECLARE @Refused TABLE (WarehouseId INT NOT NULL PRIMARY KEY, Message NVARCHAR(400) NULL);
        INSERT INTO @Refused (WarehouseId, Message)
        SELECT d.WarehouseId, security.fn_User_WarehouseRefusal(@UserId, CAST(d.WarehouseId AS NVARCHAR(12)))
        FROM (SELECT DISTINCT WarehouseId FROM #j WHERE Status IN (N'Valid', N'Warning') AND WarehouseId IS NOT NULL) d;
        UPDATE j SET Status = N'Error', Action = N'None', Message = r.Message
        FROM #j j INNER JOIN @Refused r ON r.WarehouseId = j.WarehouseId
        WHERE j.Status IN (N'Valid', N'Warning') AND r.Message IS NOT NULL;
    END

    SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemInput, j.ItemId, j.ItemCode, j.ItemName, j.ItemIsActive,
           j.WarehouseInput, j.WarehouseId, j.WarehouseCode, j.WarehouseName, j.BranchCode,
           j.MinQuantityBase, j.MaxQuantityBase, j.IsRemove, j.HasLevel, j.CurrentMinBase, j.CurrentMaxBase
    FROM #j j
    ORDER BY j.RowNumber;
END
GO

/* (91) THE IMPORT (S13): every Valid and Warning row in ONE transaction, judged again by the same function; Error and
   Unchanged rows skipped. The levels the file sets or removes are read again WITH (UPDLOCK, HOLDLOCK) inside the
   transaction (the judgement read them without a lock), so a level added, changed or removed meanwhile is counted as
   it stands now. Audit Source Import with the file name. Result 1, per row: RowNumber, Outcome (Added | Changed |
   Removed | Unchanged | Skipped), Message (the judgement's; a Skipped row's error). Result 2: the counts and the
   sentence. A 20,000-row import holds its locks until it commits: readers of the levels wait a few seconds. */
-- Re-created (92) from the body of script 91: + a row in a warehouse the user may not use is Skipped with the
-- sentence (W6, W17): the same step as the check on #j, inside the transaction and before the levels are read and
-- written, so nothing is written for it.
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_Import
    @Rows     inventory.tvp_ItemWarehouseLevelImport READONLY,
    @FileName NVARCHAR(260) = NULL,
    @UserId   INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');

    CREATE TABLE #j
    (
        RowNumber INT NOT NULL PRIMARY KEY, Status NVARCHAR(10) NOT NULL, Action NVARCHAR(10) NOT NULL, Message NVARCHAR(500) NULL,
        ItemId INT NULL, WarehouseId INT NULL, MinQuantityBase INT NULL, MaxQuantityBase INT NULL, Outcome NVARCHAR(10) NULL
    );
    CREATE TABLE #cur
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL,
        PRIMARY KEY (ItemId, WarehouseId)
    );

    DECLARE @Added INT, @Changed INT, @Removed INT, @Unchanged INT, @Skipped INT, @Message NVARCHAR(400), @Done NVARCHAR(200), @Left NVARCHAR(200);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO #j (RowNumber, Status, Action, Message, ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
        SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemId, j.WarehouseId, j.MinQuantityBase, j.MaxQuantityBase
        FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j;

        -- (92) the rows a restricted user may not import: Error, with the sentence (one call per warehouse)
        IF security.fn_User_IsUnrestricted(@UserId) = 0
        BEGIN
            DECLARE @Refused TABLE (WarehouseId INT NOT NULL PRIMARY KEY, Message NVARCHAR(400) NULL);
            INSERT INTO @Refused (WarehouseId, Message)
            SELECT d.WarehouseId, security.fn_User_WarehouseRefusal(@UserId, CAST(d.WarehouseId AS NVARCHAR(12)))
            FROM (SELECT DISTINCT WarehouseId FROM #j WHERE Status IN (N'Valid', N'Warning') AND WarehouseId IS NOT NULL) d;
            UPDATE j SET Status = N'Error', Action = N'None', Message = r.Message
            FROM #j j INNER JOIN @Refused r ON r.WarehouseId = j.WarehouseId
            WHERE j.Status IN (N'Valid', N'Warning') AND r.Message IS NOT NULL;
        END

        INSERT INTO #cur (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
        SELECT lv.ItemId, lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN #j j ON j.ItemId = lv.ItemId AND j.WarehouseId = lv.WarehouseId
        WHERE j.Status IN (N'Valid', N'Warning') AND j.Action IN (N'Set', N'Remove');

        UPDATE j
        SET Outcome = CASE WHEN j.Status = N'Error'                                   THEN N'Skipped'
                           WHEN j.Status NOT IN (N'Valid', N'Warning')                THEN N'Unchanged'
                           WHEN j.Action = N'Set' AND c.ItemId IS NULL                THEN N'Added'
                           WHEN j.Action = N'Set' AND (c.MinQuantityBase <> j.MinQuantityBase
                                                      OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(j.MaxQuantityBase, -1)) THEN N'Changed'
                           WHEN j.Action = N'Remove' AND c.ItemId IS NOT NULL         THEN N'Removed'
                           ELSE N'Unchanged' END
        FROM #j j
        LEFT JOIN #cur c ON c.ItemId = j.ItemId AND c.WarehouseId = j.WarehouseId;

        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, FileName, UserId)
        SELECT j.ItemId, j.WarehouseId, j.Outcome, c.MinQuantityBase, c.MaxQuantityBase,
               CASE WHEN j.Outcome = N'Removed' THEN NULL ELSE j.MinQuantityBase END,
               CASE WHEN j.Outcome = N'Removed' THEN NULL ELSE j.MaxQuantityBase END,
               N'Import', @FileName, @UserId
        FROM #j j
        LEFT JOIN #cur c ON c.ItemId = j.ItemId AND c.WarehouseId = j.WarehouseId
        WHERE j.Outcome IN (N'Added', N'Changed', N'Removed')
        ORDER BY j.RowNumber;

        MERGE inventory.ItemWarehouseLevels WITH (HOLDLOCK) AS t
        USING (SELECT j.ItemId, j.WarehouseId, j.MinQuantityBase, j.MaxQuantityBase FROM #j j WHERE j.Outcome IN (N'Added', N'Changed')) AS s
        ON t.ItemId = s.ItemId AND t.WarehouseId = s.WarehouseId
        WHEN MATCHED THEN
            UPDATE SET MinQuantityBase = s.MinQuantityBase, MaxQuantityBase = s.MaxQuantityBase,
                       UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase, CreatedBy, UpdatedBy)
            VALUES (s.ItemId, s.WarehouseId, s.MinQuantityBase, s.MaxQuantityBase, @UserId, @UserId);

        DELETE lv
        FROM inventory.ItemWarehouseLevels lv
        INNER JOIN #j j ON j.ItemId = lv.ItemId AND j.WarehouseId = lv.WarehouseId
        WHERE j.Outcome = N'Removed';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @Added     = ISNULL(SUM(CASE WHEN Outcome = N'Added'     THEN 1 ELSE 0 END), 0),
           @Changed   = ISNULL(SUM(CASE WHEN Outcome = N'Changed'   THEN 1 ELSE 0 END), 0),
           @Removed   = ISNULL(SUM(CASE WHEN Outcome = N'Removed'   THEN 1 ELSE 0 END), 0),
           @Unchanged = ISNULL(SUM(CASE WHEN Outcome = N'Unchanged' THEN 1 ELSE 0 END), 0),
           @Skipped   = ISNULL(SUM(CASE WHEN Outcome = N'Skipped'   THEN 1 ELSE 0 END), 0)
    FROM #j;

    -- "Stock levels imported: {a} added, {c} changed, {r} removed; {u} rows without a change and {e} rows with errors
    -- skipped." A part at 0 is left out; nothing imported: "Nothing was imported: ..."
    SET @Done = STUFF(  CASE WHEN @Added   > 0 THEN N', ' + CAST(@Added   AS NVARCHAR(10)) + N' added'   ELSE N'' END
                      + CASE WHEN @Changed > 0 THEN N', ' + CAST(@Changed AS NVARCHAR(10)) + N' changed' ELSE N'' END
                      + CASE WHEN @Removed > 0 THEN N', ' + CAST(@Removed AS NVARCHAR(10)) + N' removed' ELSE N'' END, 1, 2, N'');
    SET @Left = STUFF(  CASE WHEN @Unchanged > 0 THEN N' and ' + CAST(@Unchanged AS NVARCHAR(10))
                                                      + CASE WHEN @Unchanged = 1 THEN N' row' ELSE N' rows' END + N' without a change' ELSE N'' END
                      + CASE WHEN @Skipped   > 0 THEN N' and ' + CAST(@Skipped AS NVARCHAR(10))
                                                      + CASE WHEN @Skipped = 1 THEN N' row' ELSE N' rows' END + N' with errors' ELSE N'' END, 1, 5, N'');
    SET @Message = CASE WHEN @Done IS NULL THEN N'Nothing was imported: every row is unchanged or has an error.'
                        ELSE N'Stock levels imported: ' + @Done + ISNULL(N'; ' + @Left + N' skipped', N'') + N'.' END;

    -- 1: per row
    SELECT j.RowNumber, j.Outcome, j.Message
    FROM #j j
    ORDER BY j.RowNumber;

    -- 2: the counts and the sentence
    SELECT Added = @Added, Changed = @Changed, Removed = @Removed, Unchanged = @Unchanged, Skipped = @Skipped, Message = @Message;
END
GO

/* ================================================================== 10. Check */

-- 1. The objects (expected: none MISSING)
SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES
  (N'security.UserWarehouses'), (N'security.UserWarehouseAudit'), (N'security.fn_User_IsUnrestricted'),
  (N'security.fn_User_CanUseWarehouse'), (N'security.fn_User_Warehouses'), (N'security.fn_User_WarehouseRefusal'),
  (N'security.fn_User_WarehouseAccessText'), (N'security.usp_User_WarehouseRefusal'), (N'security.usp_User_Warehouses_Get'),
  (N'security.usp_User_SetWarehouses'), (N'security.usp_User_WarehouseSummaries'),
  (N'inventory.TR_StockMovements_WarehouseAccess'), (N'inventory.usp_TransferOrder_ToReceiveCount')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName);

-- 1b. The objects re-created by 92 carry its change (expected: none MISSING)
SELECT o.ObjectName, o.Change,
       Present = CASE WHEN OBJECT_DEFINITION(OBJECT_ID(o.ObjectName)) LIKE N'%' + o.Needle + N'%' THEN N'yes' ELSE N'MISSING' END
FROM (VALUES
  (N'masterdata.usp_Warehouse_Lookup',               N'@UserId, CanUse',   N'security.fn_User_Warehouses(@UserId)'),
  (N'masterdata.usp_Warehouse_Delete',               N'@UserId, history',  N'security.UserWarehouseAudit'),
  (N'masterdata.usp_Warehouse_Update',               N'a move, history',   N'@AccessMoved'),
  (N'inventory.fn_TransferOrder_Blocks',             N'access rows',       N'security.fn_User_WarehouseRefusal'),
  (N'inventory.usp_TransferOrder_Save',              N'the From',          N'security.fn_User_WarehouseRefusal'),
  (N'inventory.usp_TransferOrder_Search',            N'@UserId, @Mine',    N'@MineIds'),
  (N'inventory.usp_ItemWarehouseLevel_Set',          N'access',            N'security.fn_User_WarehouseRefusal'),
  (N'inventory.usp_ItemWarehouseLevel_Remove',       N'access',            N'security.fn_User_WarehouseRefusal'),
  (N'inventory.usp_ItemWarehouseLevel_ImportCheck',  N'access',            N'security.fn_User_WarehouseRefusal'),
  (N'inventory.usp_ItemWarehouseLevel_Import',       N'access',            N'security.fn_User_WarehouseRefusal')) o (ObjectName, Change, Needle);

-- 2. The trigger is enabled (expected: is_disabled = 0)
SELECT TriggerName = name, is_disabled FROM sys.triggers WHERE object_id = OBJECT_ID(N'inventory.TR_StockMovements_WarehouseAccess');

-- 3. Who is restricted (expected on the first run: 0)
SELECT RestrictedUsers = COUNT(*) FROM security.Users WHERE AllWarehouses = 0;

-- 4. No On the way warehouse ticked, no tick left on a user with All warehouses (expected: 0 rows each)
SELECT TransitTicked = uw.UserId, uw.WarehouseId FROM security.UserWarehouses uw
INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId WHERE w.IsTransit = 1;
SELECT TickOfAllWarehouses = uw.UserId, uw.WarehouseId FROM security.UserWarehouses uw
INNER JOIN security.Users u ON u.Id = uw.UserId WHERE u.AllWarehouses = 1;

-- 5. Ledger rows without a user among the 10,000 newest, written since script 92 first created the trigger (expected:
--    0; W16). Bounded by the primary key: it reads at most 10,000 rows at every start, whatever the size of the ledger
--    (a COUNT over all of it was a clustered scan, about 0.3-0.6 s on 1.5 million rows). create_date, not modify_date:
--    every start re-applies CREATE OR ALTER, which moves modify_date and keeps create_date; it is the server's local
--    time, turned into UTC for CreatedAtUtc (a SQL Server that is not on UTC, a Windows PC).
DECLARE @Check5Since DATETIME2(3) =
    (SELECT DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), MIN(create_date))
     FROM sys.triggers WHERE object_id = OBJECT_ID(N'inventory.TR_StockMovements_WarehouseAccess'));
SELECT RowsWithoutUser = COUNT(*) FROM inventory.StockMovements
WHERE Id > ISNULL((SELECT MAX(Id) FROM inventory.StockMovements), 0) - 10000
  AND CreatedBy IS NULL
  AND CreatedAtUtc >= ISNULL(@Check5Since, SYSUTCDATETIME());

PRINT 'Script 92 applied: warehouse access per user (every user keeps every warehouse until an administrator restricts one).';
GO
