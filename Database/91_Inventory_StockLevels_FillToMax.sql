SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 91: INVENTORY - STOCK LEVELS PER WAREHOUSE AND FILL TO MAX (prompt 48)

   Each warehouse keeps its own Min / Max per item, and a draft transfer order can top its destination up to them. The
   company Minimum / Maximum Quantity of Item Definition say how much the whole company should hold, never where.

     1. A STOCK LEVEL (inventory.ItemWarehouseLevels) is an item's Min (required, pcs, 0 or more) and Max (optional, not
        less than Min) in ONE warehouse at the bottom of the tree, never an On the way warehouse. Max empty: Fill to Max
        fills up to Min. An inactive warehouse takes no new or changed level; its levels may be removed. Every change is
        audited (inventory.ItemWarehouseLevelAudit: Added / Changed / Removed, old and new, who, when, from Item
        Definition, Stock Levels or an import with its file name).
     2. A LEVEL IS OWNED BY ITS ITEM AND ITS WAREHOUSE (cascading keys, decision M5): deleting either deletes its levels;
        their history stays (no key). A warehouse with levels counts as used: it cannot become a parent, with its own
        sentence. Script 90's usp_Warehouse_IsReferenced and the item delete skip the cascading keys.
     3. ONE FORMULA (inventory.fn_StockLevelState, on top of script 90's fn_TransferPosition, M6): Projected = On hand +
        On the way in + To come in - To go out, released transfer orders only (drafts, orders waiting for approval and
        purchases are not counted; L1: what released orders take OUT of the warehouse is subtracted). Status, the first
        that applies: No level; Below Min (Projected < Min); Below Min, covered (On hand < Min <= Projected, L4); Above
        Max (Projected > Max); OK. To reach Max = (Max, else Min) - Projected when Below Min. One pair:
        fn_StockPosition (fn_TransferPosition); many pairs - Stock Levels, the Dashboard, a transfer order's lines,
        Fill to Max and its drawer - fn_TransferPositions, the same sums for every pair at once, so a reader never
        reads the item's whole transfer history once per pair (Check 6 compares the two). A level is at most
        1,000,000,000 pcs, and the figures derived from it are worked out so that nothing overflows.
     4. THE COMPANY FIGURES STAY THE COMPANY'S: Inventory > Stock Levels shows them in a second view, "Company (Item
        Definition)" (usp_StockLevel_CompanySearch), which computes the Dashboard's "Items below their minimum" exactly
        (reporting.usp_Dashboard_Summary, script 72, not touched). The Dashboard gains "Warehouse levels below Min"
        (reporting.usp_Dashboard_StockLevels, read after the summary).
     5. FILL TO MAX on a saved draft (inventory.usp_TransferOrder_FillToMax; the rule in one place,
        inventory.fn_TransferFill_Plan): a preview writes nothing, the apply takes the order's RowVersion and works it out
        again. Per ITEM of the order: no level at To, an inactive item, or Projected before this order at or above Min:
        left as it is; Need = (Max, else Min) - Projected before - Ordered on the item's OTHER lines (covered when 0 or
        less); Units = Need rounded UP to whole units of the line's unit, capped at the whole units available at From (on
        hand - what other released orders still take from it - the item's other lines, never below 0; L18). The item's
        FIRST line gets Ordered = Units (set, never added, L8); its other lines never change; a second run changes
        nothing. Warnings: From goes below its own Min; other drafts / waiting orders to the same To hold the same items
        (L10). A line is red while To stays below Min AFTER the order (L19).
     6. "ADD ITEMS BELOW MIN" (inventory.usp_TransferOrder_BelowMinCandidates proposes, FillToMax with @AddItems adds):
        the same computation for items not on the order, each in the unit chosen (base by default); a filled item becomes
        a new line at the end; an item on the order is skipped ("already on the order").
     7. "CREATE TRANSFER ORDER" from ticked rows of Stock Levels (inventory.usp_TransferOrder_CreateFromLevels, L14):
        each item in its base unit, filled the same way, saved as ONE draft through script 90's usp_TransferOrder_Save;
        nothing to transfer, no draft and no number used (62009).
     8. The import (inventory.fn_ItemWarehouseLevel_ImportJudge, read by the check and the import, L13): every row judged
        Valid / Warning / Error / Unchanged; the valid and warning rows imported in ONE transaction, judged again; a
        "Remove" column; an export of the page imports back unchanged.
     9. Two permissions inventory.stocklevels.view (432) and .edit (434), granted once, when first created, to the roles
        holding View items / Edit items (L15). Fill to Max and Add items below Min come with inventory.transfers.create.

   Objects
     New tables        inventory.ItemWarehouseLevels (FK_ItemWarehouseLevels_Items / _Warehouses ON DELETE CASCADE),
                       inventory.ItemWarehouseLevelAudit
     New types         inventory.tvp_ItemWarehouseLevel, tvp_ItemWarehouseLevelImport, tvp_TransferFillItem,
                       tvp_TransferFillCandidate (frozen)
     New functions     masterdata.fn_Warehouse_IsUsedInTransactions (the body of fn_Warehouse_IsUsed as script 90 left it);
                       inventory.fn_StockLevelState (Projected, the status, To reach Max), fn_TransferPositions (script
                       90's fn_TransferPosition for every pair at once), fn_StockPosition (one pair), fn_TransferFill_Plan,
                       fn_TransferFill_Message, fn_TransferFill_FromWarning, fn_TransferFill_OtherOrdersWarning,
                       fn_ItemWarehouseLevel_ImportJudge
     New procedures    inventory.usp_StockLevel_Search, _CompanySearch; inventory.usp_ItemWarehouseLevel_Set, _Remove,
                       _History, _ImportCheck, _Import; inventory.usp_TransferOrder_FillToMax, _BelowMinCandidates,
                       _CreateFromLevels; reporting.usp_Dashboard_StockLevels
     New data, once    the two permissions and their once-grants
     Re-created        masterdata.fn_Warehouse_IsUsed               from the body of script 90: its tests moved to
                                                                    fn_Warehouse_IsUsedInTransactions, + stock levels
                       inventory.fn_TransferOrder_Blocks            from the body of script 90: + FillToMax, AddBelowMin
                       masterdata.usp_Warehouse_Create, _Update     from the body of script 90: the levels sentence of the
                                                                    used-parent refusal (52000)
                       masterdata.usp_Warehouse_Lookup              from the body of script 90: + IsUsedInTransactions,
                                                                    HasStockLevels
                       inventory.usp_Item_Delete                    from the body of script 11: the scans skip cascading keys;
                                                                    + @UserId, the levels' "Removed" audit rows
                       inventory.usp_TransferOrder_Get              from the body of script 90: + the order's levels, the
                                                                    lines' Min / Max / Projected, the two abilities
                       inventory.usp_TransferOrder_Availability     from the body of script 90: + the levels' figures

   Errors: no new number. Levels 56000 (validation), 56004 (changed or removed by another user), 56006 (not found); Fill
   to Max, Add items below Min and Create transfer order: script 90's 62000-62010; warehouses 52000.

   Not changed: masterdata.usp_Warehouse_Delete (usp_Warehouse_IsReferenced, script 90, skips the cascading level key,
   and the DELETE takes the levels), reporting.usp_Dashboard_Summary, inventory.fn_Shortage_Live (only read), the
   company Minimum / Maximum Quantity of items, every other transfer procedure; nothing here writes
   inventory.StockMovements, an item's costs or inventory.CostAdjustments.

   Requires scripts 87 and 90 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up, and
   builds a brand-new empty database (the tables and types before every object that reads them).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.TransferOrders', N'U') IS NULL                         -- 90
   OR OBJECT_ID(N'inventory.fn_TransferPosition', N'IF') IS NULL                -- 90
   OR OBJECT_ID(N'inventory.fn_TransferOrder_Blocks', N'IF') IS NULL            -- 90
   OR OBJECT_ID(N'masterdata.usp_Warehouse_IsReferenced', N'P') IS NULL         -- 90
   OR COL_LENGTH(N'inventory.Items', N'Note') IS NULL                           -- 87
    THROW 56000, 'Script 91 requires scripts 87 and 90: apply them first.', 1;
GO

/* ================================================================== 2. The tables */

-- (91) AN ITEM'S MIN / MAX IN ONE WAREHOUSE, in pcs (the item's base unit). Only a warehouse at the bottom of the tree,
--      never an On the way warehouse (the procedures check it; the Check section proves it). OWNED by the item and the
--      warehouse: deleting either deletes its levels (M5). The two cascades form no multiple path: Items -> Warehouses
--      (FK_Items_Warehouse) is NO ACTION, and no other key referencing Items or Warehouses cascades.
IF OBJECT_ID(N'inventory.ItemWarehouseLevels', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ItemWarehouseLevels
    (
        ItemId          INT          NOT NULL,
        WarehouseId     INT          NOT NULL,
        MinQuantityBase INT          NOT NULL,
        MaxQuantityBase INT          NULL,        -- NULL = no maximum: Fill to Max fills up to Min
        CreatedAtUtc    DATETIME2(3) NOT NULL CONSTRAINT DF_ItemWarehouseLevels_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy       INT          NULL,
        UpdatedAtUtc    DATETIME2(3) NOT NULL CONSTRAINT DF_ItemWarehouseLevels_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()),   -- set on insert too
        UpdatedBy       INT          NULL,
        RowVersion      ROWVERSION   NOT NULL,
        CONSTRAINT PK_ItemWarehouseLevels PRIMARY KEY CLUSTERED (ItemId, WarehouseId),
        CONSTRAINT CK_ItemWarehouseLevels_Min CHECK (MinQuantityBase >= 0),
        CONSTRAINT CK_ItemWarehouseLevels_Max CHECK (MaxQuantityBase IS NULL OR MaxQuantityBase >= MinQuantityBase),
        CONSTRAINT CK_ItemWarehouseLevels_Range CHECK (MinQuantityBase <= 1000000000 AND (MaxQuantityBase IS NULL OR MaxQuantityBase <= 1000000000)),
        CONSTRAINT FK_ItemWarehouseLevels_Items      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id)       ON DELETE CASCADE,
        CONSTRAINT FK_ItemWarehouseLevels_Warehouses FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id) ON DELETE CASCADE,
        CONSTRAINT FK_ItemWarehouseLevels_CreatedBy  FOREIGN KEY (CreatedBy)   REFERENCES security.Users (Id),
        CONSTRAINT FK_ItemWarehouseLevels_UpdatedBy  FOREIGN KEY (UpdatedBy)   REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ItemWarehouseLevels_Warehouse ON inventory.ItemWarehouseLevels (WarehouseId)
        INCLUDE (MinQuantityBase, MaxQuantityBase);
    PRINT 'Created inventory.ItemWarehouseLevels';
END
GO

-- (91) MIN AND MAX AT MOST 1,000,000,000 PCS: far above any warehouse, and far enough below the INT ceiling that "Max -
--      Projected" and Fill to Max's rounding never overflow (one level of 2,147,483,647 stopped the whole Stock Levels
--      page, Fill to Max and its drawer). A table made by a copy of this script without the rule gets it here; rows it
--      already holds are left as they are (WITH NOCHECK) rather than stopping the start-up.
IF OBJECT_ID(N'inventory.CK_ItemWarehouseLevels_Range', N'C') IS NULL
BEGIN
    IF EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels WHERE MinQuantityBase > 1000000000 OR MaxQuantityBase > 1000000000)
        ALTER TABLE inventory.ItemWarehouseLevels WITH NOCHECK ADD CONSTRAINT CK_ItemWarehouseLevels_Range
            CHECK (MinQuantityBase <= 1000000000 AND (MaxQuantityBase IS NULL OR MaxQuantityBase <= 1000000000));
    ELSE
        ALTER TABLE inventory.ItemWarehouseLevels WITH CHECK ADD CONSTRAINT CK_ItemWarehouseLevels_Range
            CHECK (MinQuantityBase <= 1000000000 AND (MaxQuantityBase IS NULL OR MaxQuantityBase <= 1000000000));
    PRINT 'Added CK_ItemWarehouseLevels_Range';
END
GO

-- (91) EVERY CHANGE OF A LEVEL (L12): old -> new, who, when, from where, the file. No key on ItemId / WarehouseId: the
--      history outlives a removed level, a deleted item or a deleted warehouse.
IF OBJECT_ID(N'inventory.ItemWarehouseLevelAudit', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ItemWarehouseLevelAudit
    (
        Id          BIGINT IDENTITY(1,1) NOT NULL,
        ItemId      INT           NOT NULL,
        WarehouseId INT           NOT NULL,
        Action      NVARCHAR(10)  NOT NULL,     -- Added | Changed | Removed
        OldMinBase  INT           NULL,
        OldMaxBase  INT           NULL,
        NewMinBase  INT           NULL,
        NewMaxBase  INT           NULL,
        Source      NVARCHAR(20)  NOT NULL,     -- ItemCard | StockLevels | Import
        FileName    NVARCHAR(260) NULL,         -- an import's file
        UserId      INT           NULL,
        AtUtc       DATETIME2(3)  NOT NULL CONSTRAINT DF_ItemWarehouseLevelAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ItemWarehouseLevelAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ItemWarehouseLevelAudit_Action CHECK (Action IN (N'Added', N'Changed', N'Removed')),
        CONSTRAINT CK_ItemWarehouseLevelAudit_Source CHECK (Source IN (N'ItemCard', N'StockLevels', N'Import')),
        CONSTRAINT FK_ItemWarehouseLevelAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ItemWarehouseLevelAudit_Level ON inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, AtUtc DESC);
    PRINT 'Created inventory.ItemWarehouseLevelAudit';
END
GO

/* ================================================================== 3. The table types (FROZEN) */

-- FROZEN: a later change takes a new type, never alters these (a type in use by a procedure cannot be altered, and
-- Schema.sql would stop at the next start). Lists of item ids reuse logistics.tvp_IdList (script 27).

-- The levels of ONE item sent by Item Definition / Stock Levels; RowVersion = the level as the page read it (NULL: new).
IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_ItemWarehouseLevel' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_ItemWarehouseLevel AS TABLE
    ( WarehouseId INT NOT NULL PRIMARY KEY, MinQuantityBase INT NULL, MaxQuantityBase INT NULL, RowVersion BINARY(8) NULL );
    PRINT 'Created type inventory.tvp_ItemWarehouseLevel';
END
GO

-- The rows of an import file as the API read them (ParseError = the sentence of an unreadable cell).
IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_ItemWarehouseLevelImport' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_ItemWarehouseLevelImport AS TABLE
    ( RowNumber INT NOT NULL PRIMARY KEY, ItemRef NVARCHAR(100) NULL, WarehouseRef NVARCHAR(150) NULL,
      MinQuantityBase INT NULL, MaxQuantityBase INT NULL, IsRemove BIT NOT NULL, ParseError NVARCHAR(300) NULL );
    PRINT 'Created type inventory.tvp_ItemWarehouseLevelImport';
END
GO

-- The drawer's ticked items (Add items below Min); ItemUnitId NULL = the item's base unit.
IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferFillItem' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferFillItem AS TABLE
    ( ItemId INT NOT NULL PRIMARY KEY, ItemUnitId INT NULL );
    PRINT 'Created type inventory.tvp_TransferFillItem';
END
GO

-- Internal: what inventory.fn_TransferFill_Plan computes for. CurrentQuantityBase = the line's stored OrderedBase (its
-- snapshot packing), so the "after" figures agree with usp_TransferOrder_Get; PackingFormula = the unit's CURRENT one.
IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferFillCandidate' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferFillCandidate AS TABLE
    ( Seq INT NOT NULL PRIMARY KEY, ItemId INT NOT NULL, ItemUnitId INT NOT NULL, PackingFormula INT NOT NULL,
      LineId INT NULL, LineNumber INT NULL, CurrentQuantity INT NULL, CurrentQuantityBase INT NULL,
      OtherLinesBase INT NOT NULL, OnOrder BIT NOT NULL );
    PRINT 'Created type inventory.tvp_TransferFillCandidate';
END
GO

/* ================================================================== 4. Used: by transactions, or by stock levels */

-- (91) A WAREHOUSE USED BY STOCK OR A DOCUMENT: the body of masterdata.fn_Warehouse_IsUsed as script 90 left it, moved
--      here unchanged. fn_Warehouse_IsUsed (re-created below) = this OR stock levels; the used-parent refusal reads both
--      to give a warehouse used only through its levels its own sentence. A later script adds its document tables HERE.
CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_IsUsedInTransactions (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM inventory.StockMovements          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocumentLines      WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocuments          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocuments              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines    WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocuments        WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM logistics.Containers              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.CostAdjustments         WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.LandedCostAdjustmentLines WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.OutOfStockSaleAudit         WHERE WarehouseId = @WarehouseId)
                  -- (72) a goods receipt names it: "Receive into" (a draft too) or a line's warehouse
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceipts            WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines        WHERE WarehouseId = @WarehouseId)
                  -- (90) a transfer order names it, as the source or the destination (a draft too)
                  OR EXISTS (SELECT 1 FROM inventory.TransferOrders          WHERE FromWarehouseId = @WarehouseId OR ToWarehouseId = @WarehouseId)
                THEN 1 ELSE 0 END;
END
GO

-- (91) A WAREHOUSE USED BY STOCK, A DOCUMENT OR STOCK LEVELS: it cannot become a parent (L5). Read by the used-parent
--      refusal of usp_Warehouse_Create / _Update and by every caller of script 90 (unchanged for a warehouse without
--      levels: its tests are fn_Warehouse_IsUsedInTransactions', moved there unchanged).
-- Re-created (91) from the body of script 90: its tests moved unchanged to fn_Warehouse_IsUsedInTransactions, + a
-- warehouse with stock levels counts as used.
CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_IsUsed (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN masterdata.fn_Warehouse_IsUsedInTransactions(@WarehouseId) = 1
                  OR EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels WHERE WarehouseId = @WarehouseId)   -- (91)
                THEN 1 ELSE 0 END;
END
GO

/* ================================================================== 5. Where a warehouse stands, Fill to Max, the import's judgement */

/* (91) THE STATUS OF A LEVEL, from where its warehouse stands (S8, S9; M6: one formula, read by every reader below):
     Projected  = On hand + On the way in + To come in - To go out
     Status     = the first that applies: NoLevel (no Min); BelowMin (Projected < Min); Covered (On hand < Min <=
                  Projected, L4); AboveMax (Max set and Projected > Max); Ok
     ToReachMax = (Max, else Min) - Projected when Below Min, else 0 - worked out in BIGINT and capped at the INT
                  ceiling, so no stored figure can make a reader fail (a level is at most 1,000,000,000 pcs anyway). */
CREATE OR ALTER FUNCTION inventory.fn_StockLevelState
(
    @OnHandBase        INT,
    @InOnTheWayBase    INT,
    @InToDispatchBase  INT,
    @OutToDispatchBase INT,
    @MinBase           INT,
    @MaxBase           INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT p.ProjectedBase,
           Status         = CAST(CASE WHEN @MinBase IS NULL                                  THEN N'NoLevel'
                                      WHEN p.ProjectedBase < @MinBase                        THEN N'BelowMin'
                                      WHEN @OnHandBase < @MinBase                            THEN N'Covered'
                                      WHEN @MaxBase IS NOT NULL AND p.ProjectedBase > @MaxBase THEN N'AboveMax'
                                      ELSE N'Ok' END AS NVARCHAR(10)),
           ToReachMaxBase = CAST(CASE WHEN @MinBase IS NULL OR p.ProjectedBase >= @MinBase THEN 0
                                      WHEN CAST(ISNULL(@MaxBase, @MinBase) AS BIGINT) - p.ProjectedBase > 2147483647 THEN 2147483647
                                      ELSE CAST(ISNULL(@MaxBase, @MinBase) AS BIGINT) - p.ProjectedBase END AS INT)
    FROM (SELECT ProjectedBase = @OnHandBase + @InOnTheWayBase + @InToDispatchBase - @OutToDispatchBase) p
);
GO

/* (91) WHAT RELEASED TRANSFER ORDERS STILL BRING TO AND TAKE FROM EVERY WAREHOUSE, per item: script 90's
   fn_TransferPosition's three sums (the same CASE) for every item and warehouse at once. For the readers of MANY pairs -
   Stock Levels, the Dashboard, Fill to Max, its drawer and Create transfer order - which called fn_TransferPosition
   once per pair and so read the item's whole transfer history once per pair (4 to 7 s for 6,000 levels on 20,000
   released orders). A transfer order's own page and a draft's availability call read a few dozen pairs: there
   fn_StockPosition, once per pair, stays the cheaper. Only the OPEN lines are summed: a line still to dispatch or on
   the way (a line received, written off or no longer sent adds 0 to every sum, so the figures are the same).
   @ExcludeOrderId leaves one order out, as fn_TransferPosition. Grouped by the line's ItemId, so a reader's filter on
   the item reaches the lines. Check 6 compares it with fn_TransferPosition. */
CREATE OR ALTER FUNCTION inventory.fn_TransferPositions (@ExcludeOrderId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT ItemId            = l.ItemId,
           x.WarehouseId,
           InOnTheWayBase    = SUM(x.InOnTheWay),
           InToDispatchBase  = SUM(x.InToDispatch),
           OutToDispatchBase = SUM(x.OutToDispatch)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    CROSS APPLY (SELECT OnTheWay   = l.DispatchedBase - l.ReceivedBase - l.LostBase,
                        ToDispatch = CASE WHEN o.NotSentAtUtc IS NULL AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                          THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END) v
    CROSS APPLY (VALUES (o.ToWarehouseId,   v.OnTheWay, v.ToDispatch, 0),            -- what it brings to To
                        (o.FromWarehouseId, 0,          0,            v.ToDispatch)) -- what it still takes from From
                x (WarehouseId, InOnTheWay, InToDispatch, OutToDispatch)
    WHERE o.Status = 2
      AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)
      AND (l.DispatchedBase - l.ReceivedBase - l.LostBase > 0 OR l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0)
    GROUP BY l.ItemId, x.WarehouseId
);
GO

-- (91) ONE ROW: WHERE A WAREHOUSE STANDS FOR AN ITEM, WITH ITS LEVEL - for ONE pair (script 90's fn_TransferPosition
--      and the level, the status of fn_StockLevelState). The readers of many pairs use fn_TransferPositions with the
--      same fn_StockLevelState; Check 6 proves the two agree (M6: one formula).
CREATE OR ALTER FUNCTION inventory.fn_StockPosition (@ItemId INT, @WarehouseId INT, @ExcludeOrderId INT)
RETURNS TABLE
AS
RETURN
(
    -- (91) WHERE A WAREHOUSE STANDS FOR AN ITEM, WITH ITS LEVEL: script 90's position (on hand, what released transfer
    --      orders bring and take, Projected) and the warehouse's Min / Max. Purchases are not counted (L11).
    SELECT p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase, p.ProjectedBase,
           HasLevel       = CAST(CASE WHEN lv.MinQuantityBase IS NULL THEN 0 ELSE 1 END AS BIT),
           MinBase        = lv.MinQuantityBase,
           MaxBase        = lv.MaxQuantityBase,
           st.Status,
           st.ToReachMaxBase
    FROM inventory.fn_TransferPosition(@ItemId, @WarehouseId, @ExcludeOrderId) p
    OUTER APPLY (SELECT v.MinQuantityBase, v.MaxQuantityBase FROM inventory.ItemWarehouseLevels v
                 WHERE v.ItemId = @ItemId AND v.WarehouseId = @WarehouseId) lv
    CROSS APPLY inventory.fn_StockLevelState(p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase,
                                             lv.MinQuantityBase, lv.MaxQuantityBase) st
);
GO

/* (91) THE WHOLE FILL TO MAX RULE IN ONE PLACE (business-context 4.14, 3.4.3), one row per candidate: Fill to Max, Add
   items below Min, the drawer's proposals and Create transfer order all read it. The positions are worked out once per
   ITEM (a unit is only a rounding), for all the candidates' items at once: what released orders bring and take
   (fn_TransferPositions, set-based) and the on hand of To and From, with fn_StockLevelState's Projected. Outcome, the
   first that applies: OnOrder (Add: the item is on the order already), Inactive, NoLevel (no level at To),
   AtOrAboveMin (Projected before this order >= Min), Covered (Need <= 0: the item's other lines cover it),
   NothingAvailable (not one whole unit available at From for the line), Filled.
     Need             = (Max, else Min) - Projected before - Ordered on the item's other lines
     AvailableFrom    = From's on hand - what other released orders still take from it, >= 0
     AvailableForLine = AvailableFrom - the item's other lines, >= 0 (L18)
     Units            = Need rounded UP to whole units of the line's unit (((n - 1) / f) + 1, f >= 1), capped at the
                        whole units available (rounded down); rounding up may pass Max by less than one unit (L7).
   Need and the units needed are worked out in BIGINT (NeedBase and UnitsNeeded go out capped at the INT ceiling), so no
   stored figure can make the plan fail; the units filled are capped by what is available, an INT.
   Min 0 needs no special case: a Projected of 0 or more is "at or above Min"; a negative Projected is filled to Max
   (else 0). @ExcludeOrderId = the order being filled, so its own lines are never counted against it. */
CREATE OR ALTER FUNCTION inventory.fn_TransferFill_Plan
(
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ExcludeOrderId  INT,
    @Candidates      inventory.tvp_TransferFillCandidate READONLY
)
RETURNS TABLE
AS
RETURN
(
    WITH it AS (SELECT DISTINCT ItemId FROM @Candidates),
    -- what released orders (this one left out) bring to and take from To and From, per item, in one pass
    tr AS
    (
        SELECT t.ItemId,
               ToIn         = SUM(CASE WHEN t.WarehouseId = @ToWarehouseId   THEN t.InOnTheWayBase    ELSE 0 END),
               ToToDispatch = SUM(CASE WHEN t.WarehouseId = @ToWarehouseId   THEN t.InToDispatchBase  ELSE 0 END),
               ToOut        = SUM(CASE WHEN t.WarehouseId = @ToWarehouseId   THEN t.OutToDispatchBase ELSE 0 END),
               FromIn       = SUM(CASE WHEN t.WarehouseId = @FromWarehouseId THEN t.InOnTheWayBase    ELSE 0 END),
               FromToDisp   = SUM(CASE WHEN t.WarehouseId = @FromWarehouseId THEN t.InToDispatchBase  ELSE 0 END),
               FromOut      = SUM(CASE WHEN t.WarehouseId = @FromWarehouseId THEN t.OutToDispatchBase ELSE 0 END)
        FROM inventory.fn_TransferPositions(@ExcludeOrderId) t
        WHERE t.ItemId IN (SELECT it.ItemId FROM it) AND t.WarehouseId IN (@ToWarehouseId, @FromWarehouseId)
        GROUP BY t.ItemId
    ),
    -- the on hand of To and From (the ledger), per item
    oh AS
    (
        SELECT m.ItemId,
               ToQty   = SUM(CASE WHEN m.WarehouseId = @ToWarehouseId   THEN m.QuantityBase ELSE 0 END),
               FromQty = SUM(CASE WHEN m.WarehouseId = @FromWarehouseId THEN m.QuantityBase ELSE 0 END)
        FROM inventory.StockMovements m
        WHERE m.ItemId IN (SELECT it.ItemId FROM it) AND m.WarehouseId IN (@ToWarehouseId, @FromWarehouseId)
        GROUP BY m.ItemId
    ),
    pos AS
    (
        SELECT it.ItemId,
               ToOnHandBase = ft.OnHand, ToInOnTheWayBase = ft.InOnTheWay, ToInToDispatchBase = ft.InToDispatch,
               ToOutToDispatchBase = ft.OutToDispatch, ProjectedBeforeBase = st.ProjectedBase,
               ToHasLevel = CAST(CASE WHEN lt.MinQuantityBase IS NULL THEN 0 ELSE 1 END AS BIT),
               MinBase = lt.MinQuantityBase, MaxBase = lt.MaxQuantityBase,
               FromOnHandBase = ff.OnHand, FromCommittedBase = ff.OutToDispatch,
               FromHasLevel = CAST(CASE WHEN lf.MinQuantityBase IS NULL THEN 0 ELSE 1 END AS BIT),
               FromMinBase = lf.MinQuantityBase, FromProjectedBeforeBase = sf.ProjectedBase,
               AvailableFromBase = CASE WHEN ff.OnHand - ff.OutToDispatch > 0 THEN ff.OnHand - ff.OutToDispatch ELSE 0 END
        FROM it
        LEFT JOIN tr ON tr.ItemId = it.ItemId
        LEFT JOIN oh ON oh.ItemId = it.ItemId
        LEFT JOIN inventory.ItemWarehouseLevels lt ON lt.ItemId = it.ItemId AND lt.WarehouseId = @ToWarehouseId
        LEFT JOIN inventory.ItemWarehouseLevels lf ON lf.ItemId = it.ItemId AND lf.WarehouseId = @FromWarehouseId
        CROSS APPLY (SELECT OnHand = ISNULL(oh.ToQty, 0), InOnTheWay = ISNULL(tr.ToIn, 0),
                            InToDispatch = ISNULL(tr.ToToDispatch, 0), OutToDispatch = ISNULL(tr.ToOut, 0)) ft
        CROSS APPLY (SELECT OnHand = ISNULL(oh.FromQty, 0), InOnTheWay = ISNULL(tr.FromIn, 0),
                            InToDispatch = ISNULL(tr.FromToDisp, 0), OutToDispatch = ISNULL(tr.FromOut, 0)) ff
        CROSS APPLY inventory.fn_StockLevelState(ft.OnHand, ft.InOnTheWay, ft.InToDispatch, ft.OutToDispatch,
                                                 lt.MinQuantityBase, lt.MaxQuantityBase) st
        CROSS APPLY inventory.fn_StockLevelState(ff.OnHand, ff.InOnTheWay, ff.InToDispatch, ff.OutToDispatch,
                                                 lf.MinQuantityBase, lf.MaxQuantityBase) sf
    )
    SELECT c.Seq, c.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive,
           c.ItemUnitId, c.PackingFormula, c.LineId, c.LineNumber, c.CurrentQuantity, c.CurrentQuantityBase, c.OtherLinesBase, c.OnOrder,
           p.ToOnHandBase, p.ToInOnTheWayBase, p.ToInToDispatchBase, p.ToOutToDispatchBase, p.ProjectedBeforeBase,
           p.ToHasLevel, p.MinBase, p.MaxBase, p.FromOnHandBase, p.FromCommittedBase,
           p.AvailableFromBase, AvailableForLineBase = av.ForLine,
           NeedBase        = CAST(CASE WHEN nd.Need > 2147483647 THEN 2147483647 WHEN nd.Need < -2147483647 THEN -2147483647
                                       ELSE nd.Need END AS INT),
           UnitsNeeded     = CAST(CASE WHEN un.UnitsNeeded > 2147483647 THEN 2147483647 ELSE un.UnitsNeeded END AS INT),
           UnitsAvailable  = un.UnitsAvailable,
           Outcome = oc.Outcome,
           NewQuantity     = CASE WHEN oc.Outcome = N'Filled' THEN un.Units END,
           NewQuantityBase = CASE WHEN oc.Outcome = N'Filled' THEN un.Units * c.PackingFormula END,
           IsCapped        = CAST(CASE WHEN oc.Outcome = N'Filled' AND un.UnitsNeeded > un.UnitsAvailable THEN 1 ELSE 0 END AS BIT),
           p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase
    FROM @Candidates c
    INNER JOIN inventory.Items i ON i.Id = c.ItemId
    INNER JOIN pos p ON p.ItemId = c.ItemId
    CROSS APPLY (SELECT ForLine = CASE WHEN p.AvailableFromBase - c.OtherLinesBase > 0 THEN p.AvailableFromBase - c.OtherLinesBase ELSE 0 END) av   -- L18
    CROSS APPLY (SELECT Need = CASE WHEN p.ToHasLevel = 1
                                    THEN CAST(ISNULL(p.MaxBase, p.MinBase) AS BIGINT) - p.ProjectedBeforeBase - c.OtherLinesBase END) nd
    CROSS APPLY (SELECT UnitsNeeded    = CASE WHEN nd.Need > 0 THEN (nd.Need - 1) / c.PackingFormula + 1 ELSE CAST(0 AS BIGINT) END,  -- round UP
                        UnitsAvailable = av.ForLine / c.PackingFormula) u0                                                                 -- whole units
    CROSS APPLY (SELECT UnitsNeeded = u0.UnitsNeeded, UnitsAvailable = u0.UnitsAvailable,
                        Units = CAST(CASE WHEN u0.UnitsNeeded < u0.UnitsAvailable THEN u0.UnitsNeeded ELSE u0.UnitsAvailable END AS INT)) un
    CROSS APPLY (SELECT Outcome = CAST(CASE WHEN c.OnOrder = 1                        THEN N'OnOrder'
                                            WHEN i.IsActive = 0                       THEN N'Inactive'
                                            WHEN p.ToHasLevel = 0                     THEN N'NoLevel'
                                            WHEN p.ProjectedBeforeBase >= p.MinBase   THEN N'AtOrAboveMin'
                                            WHEN nd.Need <= 0                         THEN N'Covered'
                                            WHEN un.UnitsAvailable = 0                THEN N'NothingAvailable'
                                            ELSE N'Filled' END AS NVARCHAR(20))) oc
);
GO

/* (91) THE RESULT SENTENCE OF FILL TO MAX, ADD ITEMS BELOW MIN AND CREATE TRANSFER ORDER (3.4.4), built in one place:
     {Head}{F} {unit}{s} {verb}[ ({C} capped by what {From} has available)][, {S} skipped ({parts})]
     [, {N} not {verb} (nothing available at {From})].[ No quantity changed.]
   Fill: "Fill to Max: ", line, filled; Add: "Add items below Min: ", item, added. {s} = s unless 1; S = every skip
   outcome; {parts} in this order, each when above 0: at or above Min, without a Min at {To}, covered by other lines of
   the item, inactive, already on the order. @NoQuantityChanged: an apply that filled lines and changed none. */
CREATE OR ALTER FUNCTION inventory.fn_TransferFill_Message
(
    @Mode              NVARCHAR(10),    -- Fill | Add
    @FromCode          NVARCHAR(20),
    @ToCode            NVARCHAR(20),
    @Filled            INT,
    @Capped            INT,
    @AtOrAboveMin      INT,
    @NoLevel           INT,
    @Covered           INT,
    @Inactive          INT,
    @OnOrder           INT,
    @NotFilled         INT,
    @NoQuantityChanged BIT
)
RETURNS NVARCHAR(500)
AS
BEGIN
    DECLARE @Add  BIT = CASE WHEN @Mode = N'Add' THEN 1 ELSE 0 END,
            @From NVARCHAR(20) = ISNULL(@FromCode, N'the source'),
            @To   NVARCHAR(20) = ISNULL(@ToCode, N'the destination');
    DECLARE @Verb NVARCHAR(10) = CASE WHEN @Add = 1 THEN N'added' ELSE N'filled' END;

    SELECT @Filled = ISNULL(@Filled, 0), @Capped = ISNULL(@Capped, 0), @AtOrAboveMin = ISNULL(@AtOrAboveMin, 0),
           @NoLevel = ISNULL(@NoLevel, 0), @Covered = ISNULL(@Covered, 0), @Inactive = ISNULL(@Inactive, 0),
           @OnOrder = ISNULL(@OnOrder, 0), @NotFilled = ISNULL(@NotFilled, 0);

    DECLARE @Skipped INT = @AtOrAboveMin + @NoLevel + @Covered + @Inactive + @OnOrder;
    DECLARE @Parts NVARCHAR(300) =
          CASE WHEN @AtOrAboveMin > 0 THEN N', ' + CAST(@AtOrAboveMin AS NVARCHAR(10)) + N' at or above Min' ELSE N'' END
        + CASE WHEN @NoLevel > 0      THEN N', ' + CAST(@NoLevel AS NVARCHAR(10)) + N' without a Min at ' + @To ELSE N'' END
        + CASE WHEN @Covered > 0      THEN N', ' + CAST(@Covered AS NVARCHAR(10)) + N' covered by other lines of the item' ELSE N'' END
        + CASE WHEN @Inactive > 0     THEN N', ' + CAST(@Inactive AS NVARCHAR(10)) + N' inactive' ELSE N'' END
        + CASE WHEN @OnOrder > 0      THEN N', ' + CAST(@OnOrder AS NVARCHAR(10)) + N' already on the order' ELSE N'' END;

    RETURN CASE WHEN @Add = 1 THEN N'Add items below Min: ' ELSE N'Fill to Max: ' END
         + CAST(@Filled AS NVARCHAR(10)) + N' ' + CASE WHEN @Add = 1 THEN N'item' ELSE N'line' END
         + CASE WHEN @Filled = 1 THEN N'' ELSE N's' END + N' ' + @Verb
         + CASE WHEN @Capped > 0 THEN N' (' + CAST(@Capped AS NVARCHAR(10)) + N' capped by what ' + @From + N' has available)' ELSE N'' END
         + CASE WHEN @Skipped > 0 THEN N', ' + CAST(@Skipped AS NVARCHAR(10)) + N' skipped (' + STUFF(@Parts, 1, 2, N'') + N')' ELSE N'' END
         + CASE WHEN @NotFilled > 0 THEN N', ' + CAST(@NotFilled AS NVARCHAR(10)) + N' not ' + @Verb + N' (nothing available at ' + @From + N')' ELSE N'' END
         + N'.'
         + CASE WHEN @NoQuantityChanged = 1 THEN N' No quantity changed.' ELSE N'' END;
END
GO

/* (91) THE TWO WARNINGS OF FILL TO MAX, ADD ITEMS BELOW MIN AND CREATE TRANSFER ORDER (3.3.6.3 step 5), each built in
   one place: From goes below its own Min for a filled item; other drafts or orders waiting for approval to the same To
   hold some of the same items (L10: Fill to Max does not count them, so a second draft for the same shortage is said). */
CREATE OR ALTER FUNCTION inventory.fn_TransferFill_FromWarning
(
    @FromCode  NVARCHAR(20),
    @ItemCode  NVARCHAR(30),
    @AfterBase INT,
    @MinBase   INT
)
RETURNS NVARCHAR(500)
AS
BEGIN
    RETURN ISNULL(@FromCode, N'The source') + N' goes below its own Min for ' + ISNULL(@ItemCode, N'the item') + N': '
           + CAST(@AfterBase AS NVARCHAR(12)) + N' pcs left after this order, Min ' + CAST(@MinBase AS NVARCHAR(12)) + N'.';
END
GO

-- (91) "Other draft or waiting transfer orders to {To} hold some of these items too ({up to 3, oldest first; a draft
--      without a number "draft #{Id}"}{ and n more}): Fill to Max does not count them." - one row, or none.
CREATE OR ALTER FUNCTION inventory.fn_TransferFill_OtherOrdersWarning
(
    @ToWarehouseId  INT,
    @ToCode         NVARCHAR(20),
    @ExcludeOrderId INT,
    @ItemIds        logistics.tvp_IdList READONLY
)
RETURNS TABLE
AS
RETURN
(
    WITH other AS
    (
        SELECT o.Id, Label = ISNULL(o.DocumentNumber, N'draft #' + CAST(o.Id AS NVARCHAR(12)))
        FROM inventory.TransferOrders o
        WHERE o.ToWarehouseId = @ToWarehouseId AND o.Status IN (1, 4)
          AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)
          AND EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                      WHERE l.TransferOrderId = o.Id AND l.ItemId IN (SELECT x.Id FROM @ItemIds x))
    )
    SELECT Message = N'Other draft or waiting transfer orders to ' + ISNULL(@ToCode, N'the destination')
                     + N' hold some of these items too (' + ISNULL(f.List, N'')
                     + CASE WHEN c.N > 3 THEN N' and ' + CAST(c.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                     + N'): Fill to Max does not count them.'
    FROM (SELECT N = COUNT(*) FROM other) c
    CROSS APPLY (SELECT List = STRING_AGG(t.Label, N', ') WITHIN GROUP (ORDER BY t.Id)
                 FROM (SELECT TOP (3) other.Id, other.Label FROM other ORDER BY other.Id) t) f
    WHERE c.N > 0
);
GO

/* (91) THE IMPORT'S WHOLE JUDGEMENT (3.4.5, S12), one row per file row, read by usp_ItemWarehouseLevel_ImportCheck AND
   usp_ItemWarehouseLevel_Import, so the check and the import never disagree. The item: its code equal to the trimmed
   text, else a unit whose barcode equals it (the code first). The warehouse: its code, else its name; a name that
   several warehouses have (and no code) is an error (L20). Status, Action and Message, the first that applies:
     1 an unreadable cell (the API's sentence)                                         Error
     2 item / warehouse missing or unknown, an ambiguous name, an On the way warehouse, a parent, the same item and
       warehouse on several rows (every such row; up to 20 row numbers, then "and n more")       Error
     3 Remove = Yes: no level -> Unchanged; Min or Max typed -> Warning (Remove); else Valid (Remove)
     4 Min and Max empty -> Unchanged; Min empty with a Max -> Error; Min below 0 -> Error; Min or Max above
       1,000,000,000 pcs -> Error; Max < Min -> Error
     5 equal to the level stored -> Unchanged     6 an inactive warehouse -> Error
     7 an inactive item -> Warning (Set)            8 else Valid (Set)
   Every Error and Unchanged row has Action None. */
CREATE OR ALTER FUNCTION inventory.fn_ItemWarehouseLevel_ImportJudge (@Rows inventory.tvp_ItemWarehouseLevelImport READONLY)
RETURNS TABLE
AS
RETURN
(
    WITH r AS
    (
        SELECT x.RowNumber, x.ParseError, x.IsRemove, x.MinQuantityBase, x.MaxQuantityBase,
               ItemInput      = NULLIF(LTRIM(RTRIM(x.ItemRef)), N''),
               WarehouseInput = NULLIF(LTRIM(RTRIM(x.WarehouseRef)), N'')
        FROM @Rows x
    ),
    res AS
    (
        SELECT r.RowNumber, r.ParseError, r.IsRemove, r.MinQuantityBase, r.MaxQuantityBase, r.ItemInput, r.WarehouseInput,
               ItemId      = COALESCE(ic.Id, ib.ItemId),
               WarehouseId = COALESCE(wc.Id, CASE WHEN wn.N = 1 THEN wn.Id END),
               NameMatches = ISNULL(wn.N, 0)
        FROM r
        OUTER APPLY (SELECT TOP (1) i.Id FROM inventory.Items i
                     WHERE r.ItemInput IS NOT NULL AND i.ItemCode = r.ItemInput) ic
        OUTER APPLY (SELECT TOP (1) u.ItemId FROM inventory.ItemUnits u
                     WHERE ic.Id IS NULL AND r.ItemInput IS NOT NULL AND u.Barcode = r.ItemInput
                     ORDER BY u.Id) ib
        OUTER APPLY (SELECT TOP (1) w.Id FROM masterdata.Warehouses w
                     WHERE r.WarehouseInput IS NOT NULL AND w.WarehouseCode = r.WarehouseInput) wc
        OUTER APPLY (SELECT N = COUNT(*), Id = MIN(w.Id) FROM masterdata.Warehouses w
                     WHERE wc.Id IS NULL AND r.WarehouseInput IS NOT NULL AND w.WarehouseName = r.WarehouseInput) wn
    ),
    ranked AS
    (
        SELECT res.*, DupRank = ROW_NUMBER() OVER (PARTITION BY res.ItemId, res.WarehouseId ORDER BY res.RowNumber)
        FROM res
    ),
    dup AS
    (
        SELECT d.ItemId, d.WarehouseId, N = COUNT(*),
               List = STRING_AGG(CASE WHEN d.DupRank <= 20 THEN CAST(d.RowNumber AS NVARCHAR(12)) END, N', ')
                          WITHIN GROUP (ORDER BY d.RowNumber)
        FROM ranked d
        WHERE d.ItemId IS NOT NULL AND d.WarehouseId IS NOT NULL
        GROUP BY d.ItemId, d.WarehouseId
        HAVING COUNT(*) > 1
    )
    SELECT x.RowNumber,
           Status  = CAST(CASE WHEN k.R BETWEEN 1 AND 9 OR k.R IN (14, 15, 16, 18, 21) THEN N'Error'
                               WHEN k.R IN (10, 13, 17)                          THEN N'Unchanged'
                               WHEN k.R IN (11, 19)                              THEN N'Warning'
                               ELSE N'Valid' END AS NVARCHAR(10)),
           Action  = CAST(CASE WHEN k.R IN (11, 12) THEN N'Remove' WHEN k.R IN (19, 20) THEN N'Set' ELSE N'None' END AS NVARCHAR(10)),
           Message = CAST(CASE k.R
                              WHEN 1  THEN x.ParseError
                              WHEN 2  THEN N'Item Code / Barcode is required.'
                              WHEN 3  THEN N'Item ' + x.ItemInput + N' not found.'
                              WHEN 4  THEN N'Warehouse is required.'
                              WHEN 5  THEN N'Warehouse ' + x.WarehouseInput + N' not found.'
                              WHEN 6  THEN N'Warehouse name ' + x.WarehouseInput + N' matches ' + CAST(x.NameMatches AS NVARCHAR(10)) + N' warehouses: use the code.'
                              WHEN 7  THEN w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot have stock levels.'
                              WHEN 8  THEN N'Warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
                              WHEN 9  THEN N'Item ' + i.ItemCode + N' at ' + w.WarehouseCode + N' is on rows ' + ISNULL(dp.List, N'')
                                           + CASE WHEN dp.N > 20 THEN N' and ' + CAST(dp.N - 20 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                           + N' of the file: keep one row.'
                              WHEN 10 THEN N'No level to remove.'
                              WHEN 11 THEN N'Remove is Yes: Min and Max are ignored.'
                              WHEN 12 THEN wm.Was
                              WHEN 13 THEN N'Nothing to change: Min and Max are empty.'
                              WHEN 14 THEN N'Min is required (a whole number, 0 or more), or put Yes in Remove.'
                              WHEN 15 THEN N'Min must be a whole number, 0 or more.'
                              WHEN 16 THEN N'Max cannot be less than Min.'
                              WHEN 17 THEN N'No change.'
                              WHEN 18 THEN N'Warehouse ' + w.WarehouseCode + N' is inactive: activate it to change its levels.'
                              WHEN 19 THEN N'Item ' + i.ItemCode + N' is inactive: Fill to Max skips it.'
                              WHEN 21 THEN N'Min and Max can be at most 1,000,000,000 pcs.'
                              ELSE wm.Was END AS NVARCHAR(500)),   -- 20: NULL for a new level
           x.ItemInput, x.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive,
           x.WarehouseInput, x.WarehouseId, w.WarehouseCode, w.WarehouseName, b.BranchCode,
           x.MinQuantityBase, x.MaxQuantityBase, x.IsRemove,
           HasLevel       = CAST(CASE WHEN lv.ItemId IS NULL THEN 0 ELSE 1 END AS BIT),
           CurrentMinBase = lv.MinQuantityBase,
           CurrentMaxBase = lv.MaxQuantityBase
    FROM res x
    LEFT JOIN inventory.Items i                ON i.Id = x.ItemId
    LEFT JOIN masterdata.Warehouses w          ON w.Id = x.WarehouseId
    LEFT JOIN masterdata.Branches b            ON b.Id = w.BranchId
    LEFT JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = x.ItemId AND lv.WarehouseId = x.WarehouseId
    LEFT JOIN dup dp                           ON dp.ItemId = x.ItemId AND dp.WarehouseId = x.WarehouseId
    CROSS APPLY (SELECT Was = CASE WHEN lv.ItemId IS NOT NULL
                                   THEN N'Was Min ' + CAST(lv.MinQuantityBase AS NVARCHAR(12)) + N' / '
                                        + CASE WHEN lv.MaxQuantityBase IS NULL THEN N'no Max'
                                               ELSE N'Max ' + CAST(lv.MaxQuantityBase AS NVARCHAR(12)) END + N'.' END) wm
    CROSS APPLY (SELECT R = CASE
            WHEN x.ParseError IS NOT NULL                                                   THEN 1
            WHEN x.ItemInput IS NULL                                                        THEN 2
            WHEN x.ItemId IS NULL                                                           THEN 3
            WHEN x.WarehouseInput IS NULL                                                   THEN 4
            WHEN x.WarehouseId IS NULL AND x.NameMatches = 0                                THEN 5
            WHEN x.WarehouseId IS NULL                                                      THEN 6
            WHEN w.IsTransit = 1                                                            THEN 7
            WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)     THEN 8
            WHEN dp.N > 1                                                                   THEN 9
            WHEN x.IsRemove = 1 AND lv.ItemId IS NULL                                       THEN 10
            WHEN x.IsRemove = 1 AND (x.MinQuantityBase IS NOT NULL OR x.MaxQuantityBase IS NOT NULL) THEN 11
            WHEN x.IsRemove = 1                                                             THEN 12
            WHEN x.MinQuantityBase IS NULL AND x.MaxQuantityBase IS NULL                    THEN 13
            WHEN x.MinQuantityBase IS NULL                                                  THEN 14
            WHEN x.MinQuantityBase < 0                                                      THEN 15
            WHEN x.MinQuantityBase > 1000000000 OR x.MaxQuantityBase > 1000000000            THEN 21
            WHEN x.MaxQuantityBase < x.MinQuantityBase                                      THEN 16
            WHEN lv.ItemId IS NOT NULL AND lv.MinQuantityBase = x.MinQuantityBase
                 AND ISNULL(lv.MaxQuantityBase, -1) = ISNULL(x.MaxQuantityBase, -1)         THEN 17
            WHEN w.IsActive = 0                                                             THEN 18
            WHEN i.IsActive = 0                                                             THEN 19
            ELSE 20 END) k
);
GO

/* (91) WHY AN ACTION ON A TRANSFER ORDER CANNOT BE DONE NOW (script 90's rules, one row per failed rule; the first row
   of an action is its reason), + Fill to Max and Add items below Min (spec 3.3.3.6): a draft only (62010 while waiting
   for approval, 62005 released or cancelled), the TRO type on (62008), warehouses an order can hold (62000), lines for
   Fill (62009), and stock levels at To for an active item (62009). Read by usp_TransferOrder_FillToMax,
   _BelowMinCandidates and usp_TransferOrder_Get (CanFillToMax / CanAddBelowMin). Needs inventory.ItemWarehouseLevels
   (section 2). */
-- Re-created (91) from the body of script 90: + FillToMax, AddBelowMin (the Seq 1 list, the order's ToCode / HasLines /
-- HasToLevels, the rows 130-134).
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
) b;
GO

/* ================================================================== 6. Master data and item procedures re-created (3.3.4) */

/* (91) CREATE A WAREHOUSE (script 90's rules): a parent with stock levels and nothing else gets its own sentence. */
-- Re-created (91) from the body of script 90: + the levels sentence of the used-parent refusal (52000) when the parent
-- is used only through its stock levels (fn_Warehouse_IsUsedInTransactions = 0); otherwise today's sentence.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Create
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,
    @ParentId             INT           = NULL,   -- NULL = a root warehouse
    @AllowOutOfStockOverride BIT        = NULL,   -- NULL = follow the global setting
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
    -- (90) an On the way warehouse holds goods on the road, never other warehouses
    IF @ParentId IS NOT NULL AND EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId AND IsTransit = 1)
        THROW 52000, 'An On the way warehouse cannot hold other warehouses. Choose another parent warehouse.', 1;
    IF @ParentId IS NOT NULL AND masterdata.fn_Warehouse_IsUsed(@ParentId) = 1
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

        INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive, ParentId, [Level], CreatedBy, AllowOutOfStockOverride)
        VALUES (@WarehouseCode, @WarehouseName, @BranchId, @Address, @IsMainWarehouse, @IsActive, @ParentId, @Level, @UserId, @AllowOutOfStockOverride);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* (91) CHANGE A WAREHOUSE (script 90's rules): the same sentence as Create for a new parent used only through levels. */
-- Re-created (91) from the body of script 90: + the levels sentence of the used-parent refusal (52000) when the new
-- parent is used only through its stock levels (fn_Warehouse_IsUsedInTransactions = 0); otherwise today's sentence.
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

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* (91) THE WAREHOUSES A DROPDOWN OFFERS (script 90's rows and columns), + why one counts as used: by stock or a
   document (IsUsedInTransactions), by stock levels (HasStockLevels). IsUsed = either, as fn_Warehouse_IsUsed says; each
   test is worked out once a row (the parent picker labels a warehouse that has levels and nothing else). */
-- Re-created (91) from the body of script 90: + IsUsedInTransactions and HasStockLevels (the two last columns), IsUsed
-- from them (same rows, same values).
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL,
    @IncludeTransit BIT = 0   -- (90) 1 = the branches' On the way warehouses too
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName,
           w.IsMainWarehouse, w.IsActive, w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           IsUsed     = CAST(u.T | u.L AS BIT),                             -- (91) = fn_Warehouse_IsUsed, worked out once
           w.IsTransit,                                                    -- (90)
           IsUsedInTransactions = u.T,                                     -- (91) stock or a document names it
           HasStockLevels       = u.L                                      -- (91) it has stock levels
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

/* (91) DELETE AN ITEM never transacted, with its units and files - and its stock levels, which the cascading key
   deletes with it (L5; their history stays, and says so: a "Removed" row per level, from Item Definition, by @UserId -
   S4). Only a key that does NOT cascade is a reference: a cascading child (the levels) is owned by the item. 56003 /
   56006 unchanged. */
-- Re-created (91) from the body of script 11: both generic scans + AND fk.delete_referential_action = 0; + @UserId and
-- the levels' "Removed" audit rows.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Delete
    @Id     INT,
    @UserId INT = NULL
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
      AND fk.parent_object_id NOT IN (OBJECT_ID(N'inventory.ItemUnits'), OBJECT_ID(N'inventory.ItemFiles'))
      AND fk.delete_referential_action = 0;   -- (91) a cascading child (the stock levels) is owned, not a reference

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
        WHERE fk.referenced_object_id = OBJECT_ID(N'inventory.ItemUnits')
          AND fk.delete_referential_action = 0;   -- (91) a cascading child is owned, not a reference

        IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    END

    IF @Referenced = 1
        THROW 56003, 'This item cannot be deleted because it is referenced by inventory or transactions. You may deactivate it instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        -- (91) the levels go with the item (the cascading key): their history records it (S4)
        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, UserId)
        SELECT lv.ItemId, lv.WarehouseId, N'Removed', lv.MinQuantityBase, lv.MaxQuantityBase, NULL, NULL, N'ItemCard', @UserId
        FROM inventory.ItemWarehouseLevels lv
        WHERE lv.ItemId = @Id;
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

/* ================================================================== 7. The stock level procedures */

/* (91) INVENTORY > STOCK LEVELS, "Per warehouse" (and the item card, with @ItemId, activeItemsOnly 0, inactive
   warehouses too): every level of the scope with where its warehouse stands, or (@Status NoLevel) the item /
   warehouse pairs of the scope WITHOUT a level that hold stock (a ledger balance other than 0) or appear on a released
   transfer order (as To with goods on the way or to dispatch, as From with goods to dispatch). Scope: warehouses at
   the bottom of the tree, never On the way, active unless @IncludeInactiveWarehouses; @WarehouseId = that warehouse or
   the leaves under it; @ItemFamilyId = the family and its sub-families; @Search = item code or name (LIKE) or a unit's
   barcode (exactly). Result 1: the rows, Below Min first, then Below Min covered, Above Max, OK (then the pairs without
   a level), item code, warehouse code. Result 2: the scope's totals, levels only, whatever @Status. */
CREATE OR ALTER PROCEDURE inventory.usp_StockLevel_Search
    @Search                    NVARCHAR(100) = NULL,
    @BranchId                  INT           = NULL,
    @WarehouseId               INT           = NULL,
    @ItemFamilyId              INT           = NULL,
    @BrandId                   INT           = NULL,
    @ItemId                    INT           = NULL,
    @Status                    NVARCHAR(20)  = NULL,
    @ActiveItemsOnly           BIT           = 1,
    @IncludeInactiveWarehouses BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    SET @ActiveItemsOnly = ISNULL(@ActiveItemsOnly, 1);
    SET @IncludeInactiveWarehouses = ISNULL(@IncludeInactiveWarehouses, 0);

    IF @Status IS NOT NULL AND @Status NOT IN (N'BelowMin', N'Covered', N'AboveMax', N'Ok', N'NoLevel')
        THROW 56000, 'Unknown status: choose Below Min, Below Min covered, Above Max, OK or Without a level.', 1;

    -- The warehouses of the scope
    CREATE TABLE #wh (Id INT NOT NULL PRIMARY KEY);
    DECLARE @Under TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Under (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;

    INSERT INTO #wh (Id)
    SELECT w.Id
    FROM masterdata.Warehouses w
    WHERE w.IsTransit = 0
      AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
      AND (w.IsActive = 1 OR @IncludeInactiveWarehouses = 1)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR w.Id IN (SELECT u.Id FROM @Under u));

    -- The items of the scope
    CREATE TABLE #it (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO #it (Id)
    SELECT i.Id
    FROM inventory.Items i
    WHERE (@ActiveItemsOnly = 0 OR i.IsActive = 1)
      AND (@ItemId IS NULL OR i.Id = @ItemId)
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.Barcode = @Search));

    -- The pairs of the scope: every level, and (Without a level) the pairs without one that hold stock (a ledger balance
    -- other than 0) or appear on a released transfer order (as To with goods on the way or to dispatch, as From with
    -- goods to dispatch)
    CREATE TABLE #pr (ItemId INT NOT NULL, WarehouseId INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #pr (ItemId, WarehouseId)
    SELECT lv.ItemId, lv.WarehouseId
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN #wh w ON w.Id = lv.WarehouseId
    INNER JOIN #it i ON i.Id = lv.ItemId;

    -- What released transfer orders bring to and take from the scope's warehouses, every pair at once
    -- (fn_TransferPositions: fn_TransferPosition's sums, set-based - read once per pair they cost the item's whole
    -- transfer history each time)
    CREATE TABLE #tp
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL,
        OutToDispatchBase INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId)
    );
    INSERT INTO #tp (ItemId, WarehouseId, InOnTheWayBase, InToDispatchBase, OutToDispatchBase)
    SELECT tp.ItemId, tp.WarehouseId, tp.InOnTheWayBase, tp.InToDispatchBase, tp.OutToDispatchBase
    FROM inventory.fn_TransferPositions(NULL) tp
    INNER JOIN #wh w ON w.Id = tp.WarehouseId
    INNER JOIN #it i ON i.Id = tp.ItemId;

    IF @Status = N'NoLevel'
        INSERT INTO #pr (ItemId, WarehouseId)
        SELECT x.ItemId, x.WarehouseId
        FROM
        (
            SELECT m.ItemId, m.WarehouseId
            FROM inventory.StockMovements m
            INNER JOIN #wh w ON w.Id = m.WarehouseId
            INNER JOIN #it i ON i.Id = m.ItemId
            GROUP BY m.ItemId, m.WarehouseId
            HAVING SUM(m.QuantityBase) <> 0
            UNION
            SELECT tp.ItemId, tp.WarehouseId
            FROM #tp tp
            WHERE tp.InOnTheWayBase + tp.InToDispatchBase > 0 OR tp.OutToDispatchBase > 0
        ) x
        WHERE NOT EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels lv WHERE lv.ItemId = x.ItemId AND lv.WarehouseId = x.WarehouseId);

    -- Where each pair stands, worked out once for every pair: the ledger's on hand, what released transfer orders bring
    -- and take (#tp), the level, and fn_StockLevelState's Projected and status (M6: the formula of fn_StockPosition)
    CREATE TABLE #pos
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, HasLevel BIT NOT NULL, MinQuantityBase INT NULL, MaxQuantityBase INT NULL,
        OnHandBase INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL, OutToDispatchBase INT NOT NULL,
        ProjectedBase INT NOT NULL, ToReachMaxBase INT NOT NULL, Status NVARCHAR(10) NOT NULL,
        PRIMARY KEY (ItemId, WarehouseId)
    );

    INSERT INTO #pos (ItemId, WarehouseId, HasLevel, MinQuantityBase, MaxQuantityBase, OnHandBase, InOnTheWayBase,
                      InToDispatchBase, OutToDispatchBase, ProjectedBase, ToReachMaxBase, Status)
    SELECT pr.ItemId, pr.WarehouseId, CAST(CASE WHEN lv.ItemId IS NULL THEN 0 ELSE 1 END AS BIT), lv.MinQuantityBase, lv.MaxQuantityBase,
           q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase, st.ProjectedBase, st.ToReachMaxBase, st.Status
    FROM #pr pr
    LEFT JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = pr.ItemId AND lv.WarehouseId = pr.WarehouseId
    LEFT JOIN #tp tp ON tp.ItemId = pr.ItemId AND tp.WarehouseId = pr.WarehouseId
    LEFT JOIN (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
               FROM inventory.StockMovements m
               INNER JOIN #pr x ON x.ItemId = m.ItemId AND x.WarehouseId = m.WarehouseId
               GROUP BY m.ItemId, m.WarehouseId) oh ON oh.ItemId = pr.ItemId AND oh.WarehouseId = pr.WarehouseId
    CROSS APPLY (SELECT OnHandBase = ISNULL(oh.Qty, 0), InOnTheWayBase = ISNULL(tp.InOnTheWayBase, 0),
                        InToDispatchBase = ISNULL(tp.InToDispatchBase, 0), OutToDispatchBase = ISNULL(tp.OutToDispatchBase, 0)) q
    CROSS APPLY inventory.fn_StockLevelState(q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase,
                                             lv.MinQuantityBase, lv.MaxQuantityBase) st;

    -- 1: the rows
    SELECT p.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive, ItemFamilyName = f.FamilyName, b.BrandName,
           p.WarehouseId, w.WarehouseCode, w.WarehouseName, WarehouseIsActive = w.IsActive,
           w.BranchId, br.BranchCode, br.BranchName,
           p.HasLevel, p.MinQuantityBase, p.MaxQuantityBase,
           p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase, p.ProjectedBase, p.ToReachMaxBase, p.Status,
           lv.UpdatedAtUtc, UpdatedByName = u.FullName, RowVersion = CAST(lv.RowVersion AS BINARY(8))
    FROM #pos p
    INNER JOIN inventory.Items i            ON i.Id = p.ItemId
    INNER JOIN masterdata.Warehouses w      ON w.Id = p.WarehouseId
    INNER JOIN masterdata.Branches br       ON br.Id = w.BranchId
    LEFT  JOIN masterdata.ItemFamilies f    ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b          ON b.Id = i.BrandId
    LEFT  JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = p.ItemId AND lv.WarehouseId = p.WarehouseId
    LEFT  JOIN security.Users u             ON u.Id = lv.UpdatedBy
    WHERE @Status IS NULL OR p.Status = @Status
    ORDER BY CASE p.Status WHEN N'BelowMin' THEN 1 WHEN N'Covered' THEN 2 WHEN N'AboveMax' THEN 3 WHEN N'Ok' THEN 4 ELSE 5 END,
             i.ItemCode, w.WarehouseCode;

    -- 2: the scope's totals (levels only, the status filter ignored)
    SELECT Levels   = COUNT(*),
           BelowMin = ISNULL(SUM(CASE WHEN p.Status = N'BelowMin' THEN 1 ELSE 0 END), 0),
           Covered  = ISNULL(SUM(CASE WHEN p.Status = N'Covered'  THEN 1 ELSE 0 END), 0),
           AboveMax = ISNULL(SUM(CASE WHEN p.Status = N'AboveMax' THEN 1 ELSE 0 END), 0),
           Ok       = ISNULL(SUM(CASE WHEN p.Status = N'Ok'       THEN 1 ELSE 0 END), 0)
    FROM #pos p
    WHERE p.HasLevel = 1;
END
GO

/* (91) INVENTORY > STOCK LEVELS, "Company (Item Definition)" (L2): the item's company Minimum / Maximum Quantity against
   the stock of a branch or the company. Result 1: the items with a company Min (above 0) or a Max, Below Min first by
   what is missing, then item code; WarehouseLevelCount = the item's levels at the active warehouses of the scope (what
   "Per warehouse" shows for the item with the same branch). Result 2: the scope's totals (the status filter ignored):
   with the defaults, BelowMin is the Dashboard's "Items below their minimum" for the same branch. Result 3: the scope
   (BranchId NULL = the company). */
CREATE OR ALTER PROCEDURE inventory.usp_StockLevel_CompanySearch
    @Search          NVARCHAR(100) = NULL,
    @BranchId        INT           = NULL,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Status          NVARCHAR(20)  = NULL,
    @ActiveItemsOnly BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    SET @ActiveItemsOnly = ISNULL(@ActiveItemsOnly, 1);

    IF @Status IS NOT NULL AND @Status NOT IN (N'BelowMin', N'AboveMax', N'Ok')
        THROW 56000, 'Unknown status: choose Below Min, Above Max or OK.', 1;

    -- (91) THE DASHBOARD'S OWN FORMULA (reporting.usp_Dashboard_Summary, script 72): the stock of EVERY warehouse of the
    --      branch - inactive ones and its On the way warehouse included - or of the company, against the item's company
    --      Minimum Quantity. Change one, change both (test f compares them).
    DECLARE @Stock TABLE (ItemId INT NOT NULL PRIMARY KEY, OnHand INT NOT NULL);
    INSERT INTO @Stock (ItemId, OnHand)
    SELECT m.ItemId, SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId
    GROUP BY m.ItemId;

    CREATE TABLE #co
    (
        ItemId INT NOT NULL PRIMARY KEY, OnHandBase INT NOT NULL, Status NVARCHAR(10) NOT NULL, MissingBase INT NOT NULL
    );
    INSERT INTO #co (ItemId, OnHandBase, Status, MissingBase)
    SELECT i.Id, s.OnHand,
           CASE WHEN i.MinQuantity > 0 AND s.OnHand < i.MinQuantity               THEN N'BelowMin'
                WHEN i.MaxQuantity IS NOT NULL AND s.OnHand > i.MaxQuantity       THEN N'AboveMax'
                ELSE N'Ok' END,
           CASE WHEN i.MinQuantity > 0 AND s.OnHand < i.MinQuantity THEN i.MinQuantity - s.OnHand ELSE 0 END
    FROM inventory.Items i
    CROSS APPLY (SELECT OnHand = ISNULL((SELECT st.OnHand FROM @Stock st WHERE st.ItemId = i.Id), 0)) s
    WHERE (i.MinQuantity > 0 OR i.MaxQuantity IS NOT NULL)
      AND (@ActiveItemsOnly = 0 OR i.IsActive = 1)
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.Barcode = @Search));

    -- 1: the items
    SELECT c.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive, ItemFamilyName = f.FamilyName, b.BrandName,
           c.OnHandBase, i.MinQuantity, i.MaxQuantity, c.Status, c.MissingBase,
           WarehouseLevelCount = (SELECT COUNT(*)
                                  FROM inventory.ItemWarehouseLevels lv
                                  INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId AND w.IsActive = 1
                                  WHERE lv.ItemId = c.ItemId AND (@BranchId IS NULL OR w.BranchId = @BranchId))
    FROM #co c
    INNER JOIN inventory.Items i         ON i.Id = c.ItemId
    LEFT  JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b       ON b.Id = i.BrandId
    WHERE @Status IS NULL OR c.Status = @Status
    ORDER BY CASE WHEN c.Status = N'BelowMin' THEN 0 ELSE 1 END, c.MissingBase DESC, i.ItemCode;

    -- 2: the totals of the scope
    SELECT Items = COUNT(*), BelowMin = ISNULL(SUM(CASE WHEN c.Status = N'BelowMin' THEN 1 ELSE 0 END), 0)
    FROM #co c;

    -- 3: the scope
    SELECT BranchId = b.Id, BranchName = b.BranchName
    FROM (SELECT Id = @BranchId) s
    LEFT JOIN masterdata.Branches b ON b.Id = s.Id;
END
GO

/* (91) SET AN ITEM'S LEVELS IN ONE OR MORE WAREHOUSES (Item Definition's card, Stock Levels), all or nothing. The checks,
   the first failing row by warehouse code (56000): the warehouse exists, is not On the way, has no warehouses under
   it, is active (a new or changed level only: L6), Min is a whole number 0 or more, Min and Max are at most
   1,000,000,000 pcs, Max is not below Min. Then, in the transaction, each row sent with a RowVersion is compared with
   the level as it stands, read WITH (UPDLOCK, HOLDLOCK) (56004: removed / changed by another user); a row without one
   is a NEW level: when somebody else has set one there meanwhile with another Min or Max, 56004 "... was added by
   another user" - never a silent overwrite.
   An unchanged row is neither rewritten nor audited. @Source ItemCard | StockLevels (anything else: ItemCard). No
   result set. */
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

-- (91) THE HISTORY OF ONE LEVEL, newest first (it outlives the level: a removed level's history still reads).
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_History
    @ItemId      INT,
    @WarehouseId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AtUtc, a.Action, a.OldMinBase, a.OldMaxBase, a.NewMinBase, a.NewMaxBase, a.Source, a.FileName,
           UserName = u.FullName
    FROM inventory.ItemWarehouseLevelAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ItemId = @ItemId AND a.WarehouseId = @WarehouseId
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

-- (91) THE IMPORT'S CHECK STEP: the judgement of every row (inventory.fn_ItemWarehouseLevel_ImportJudge), nothing
--      written. @UserId is read by script 92 (warehouse access).
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_ImportCheck
    @Rows   inventory.tvp_ItemWarehouseLevelImport READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemInput, j.ItemId, j.ItemCode, j.ItemName, j.ItemIsActive,
           j.WarehouseInput, j.WarehouseId, j.WarehouseCode, j.WarehouseName, j.BranchCode,
           j.MinQuantityBase, j.MaxQuantityBase, j.IsRemove, j.HasLevel, j.CurrentMinBase, j.CurrentMaxBase
    FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j
    ORDER BY j.RowNumber;
END
GO

/* (91) THE IMPORT (S13): every Valid and Warning row in ONE transaction, judged again by the same function; Error and
   Unchanged rows skipped. The levels the file sets or removes are read again WITH (UPDLOCK, HOLDLOCK) inside the
   transaction (the judgement read them without a lock), so a level added, changed or removed meanwhile is counted as
   it stands now. Audit Source Import with the file name. Result 1, per row: RowNumber, Outcome (Added | Changed |
   Removed | Unchanged | Skipped), Message (the judgement's; a Skipped row's error). Result 2: the counts and the
   sentence. A 20,000-row import holds its locks until it commits: readers of the levels wait a few seconds. */
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

/* ================================================================== 8. The transfer procedures */

/* (91) ONE TRANSFER ORDER, script 90's six result sets with every column, + the destination's stock levels (3.3.6.1):
     1 header + ToLevelCount (levels at To of active items), ItemsBelowMin (the items whose lines are red),
       CanFillToMax / FillToMaxBlockedReason and CanAddBelowMin / AddBelowMinBlockedReason (fn_TransferOrder_Blocks)
     2 lines + ToHasLevel, ToMinBase, ToMaxBase, ToOutToDispatchBase, ToProjectedBeforeBase, ToProjectedAfterBase,
       IsBelowMin, FromHasLevel, FromMinBase, FromProjectedBeforeBase, FromAfterBase, FromBelowMinAfter: fn_StockPosition
       of the item at To and at From with this order left out, then what this order brings (Ordered while a draft or
       waiting, To dispatch + On the way once released, nothing cancelled) and takes (Ordered, To dispatch, nothing).
       Script 90's five figures keep their names and values (fn_StockPosition reads the same fn_TransferPosition). */
-- Re-created (91) from the body of script 90: + the order's levels and the two abilities (result 1), the lines' Min /
-- Max / Projected at To and From after this order (result 2).
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Get
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- THE REFUSALS OF EVERY ACTION, read once: the first row (lowest Seq) of an action is its reason.
    DECLARE @B TABLE (Action NVARCHAR(30) NOT NULL PRIMARY KEY, Message NVARCHAR(400) NOT NULL);
    INSERT INTO @B (Action, Message)
    SELECT k.Action, k.Message
    FROM (SELECT b.Action, b.Message, Rn = ROW_NUMBER() OVER (PARTITION BY b.Action ORDER BY b.Seq)
          FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
          WHERE b.Message IS NOT NULL) k
    WHERE k.Rn = 1;

    -- The three order-level answers of the postings, computed once (92 adds its access rows to them).
    DECLARE @ReverseDispatch NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ReverseDispatch'),
            @ReverseReceipt  NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ReverseReceipt'),
            @ChangeEta       NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ChangeEta');

    -- (91) WHAT THIS ORDER BRINGS TO To AND TAKES FROM From, per item (3.3.6.1), read by the header (ItemsBelowMin) and
    --      the lines: a draft or an order waiting for approval its Ordered; a released one what it still has to dispatch
    --      (+ what is on the way, for To; what was received is in To's on hand already); a cancelled one nothing.
    DECLARE @BT TABLE (ItemId INT NOT NULL PRIMARY KEY, BringsBase INT NOT NULL, TakesBase INT NOT NULL);
    INSERT INTO @BT (ItemId, BringsBase, TakesBase)
    SELECT l.ItemId,
           BringsBase = SUM(CASE o.Status WHEN 2 THEN td.ToDispatch + (l.DispatchedBase - l.ReceivedBase - l.LostBase)
                                          WHEN 3 THEN 0 ELSE l.OrderedBase END),
           TakesBase  = SUM(CASE o.Status WHEN 2 THEN td.ToDispatch WHEN 3 THEN 0 ELSE l.OrderedBase END)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    CROSS APPLY (SELECT ToDispatch = CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                          THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END) td
    WHERE l.TransferOrderId = @Id
    GROUP BY l.ItemId;

    -- (91) WHERE From AND To STAND FOR THE ORDER'S ITEMS, this order left out: fn_StockPosition (script 90's five
    --      figures + the level), ONCE per item and warehouse - read by the header (ItemsBelowMin) and by every line of
    --      the item. (It ran once per line and once more per item for the header: the regression review's 2-3 times
    --      script 90's reads.) A table variable: the order page's plan is kept between calls.
    DECLARE @FromId INT, @ToId INT;
    SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId FROM inventory.TransferOrders WHERE Id = @Id;

    DECLARE @SP TABLE
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, OnHandBase INT NOT NULL, InOnTheWayBase INT NOT NULL,
        InToDispatchBase INT NOT NULL, OutToDispatchBase INT NOT NULL, ProjectedBase INT NOT NULL, HasLevel BIT NOT NULL,
        MinBase INT NULL, MaxBase INT NULL, PRIMARY KEY (ItemId, WarehouseId)
    );
    INSERT INTO @SP (ItemId, WarehouseId, OnHandBase, InOnTheWayBase, InToDispatchBase, OutToDispatchBase, ProjectedBase,
                     HasLevel, MinBase, MaxBase)
    SELECT bt.ItemId, w.WarehouseId, sp.OnHandBase, sp.InOnTheWayBase, sp.InToDispatchBase, sp.OutToDispatchBase,
           sp.ProjectedBase, sp.HasLevel, sp.MinBase, sp.MaxBase
    FROM @BT bt
    CROSS JOIN (VALUES (@FromId), (@ToId)) w (WarehouseId)
    CROSS APPLY inventory.fn_StockPosition(bt.ItemId, w.WarehouseId, @Id) sp;

    -- 1: header
    SELECT o.Id, o.DocumentTypeId, o.DocumentNumber, o.DocumentDate,
           o.BranchId, b.BranchCode, b.BranchName,
           o.FromWarehouseId, FromWarehouseCode = fw.WarehouseCode, FromWarehouseName = fw.WarehouseName,
           FromBranchId = fw.BranchId, FromBranchCode = fb.BranchCode, FromBranchName = fb.BranchName,
           o.ToWarehouseId, ToWarehouseCode = tw.WarehouseCode, ToWarehouseName = tw.WarehouseName,
           ToBranchId = tw.BranchId, ToBranchCode = tb.BranchCode, ToBranchName = tb.BranchName,
           o.ExpectedArrival, o.ReferenceNo, o.Notes,
           o.Status, StatusCode = CASE o.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           o.ReturnOfOrderId, ReturnOfNumber = ro.DocumentNumber,
           o.TotalLines, o.TotalOrderedBase,
           o.ApprovalRequestedAtUtc, o.ApprovalRequestedBy, ApprovalRequestedByName = rqu.FullName,
           o.ApprovedAtUtc, o.ApprovedBy, ApprovedByName = apu.FullName, o.ApprovedDirectly,
           o.RejectedAtUtc, o.RejectedBy, RejectedByName = rju.FullName, o.RejectReason,
           o.ReleasedAtUtc, o.ReleasedBy, ReleasedByName = rlu.FullName,
           o.NotSentAtUtc, o.NotSentBy, NotSentByName = nsu.FullName, o.NotSentReason,
           o.CancelledAtUtc, o.CancelledBy, CancelledByName = cxu.FullName, o.CancelReason,
           o.CreatedAtUtc, o.CreatedBy, CreatedByName = cu.FullName, o.UpdatedAtUtc, o.UpdatedBy, UpdatedByName = uu.FullName,
           NeedsApproval = dt.NeedsApproval, NumberOnPost = dt.NumberOnPost,
           OrderedBase    = ISNULL(st.OrderedBase, 0),    DispatchedBase = ISNULL(st.DispatchedBase, 0),
           ReceivedBase   = ISNULL(st.ReceivedBase, 0),   LostBase       = ISNULL(st.LostBase, 0),
           NotSentBase    = ISNULL(st.NotSentBase, 0),    ToDispatchBase = ISNULL(st.ToDispatchBase, 0),
           OnTheWayBase   = ISNULL(st.OnTheWayBase, 0),   ItemCount      = ISNULL(st.ItemCount, 0),
           LateDispatches = ISNULL(st.LateDispatches, 0), IsLate         = CAST(ISNULL(st.IsLate, 0) AS BIT),
           st.DisplayStatus,
           OnTheWayValueBase = CAST(ISNULL(v.Value, 0) AS DECIMAL(18,2)),
           CanEdit               = CAST(CASE WHEN k.EditR               IS NULL THEN 1 ELSE 0 END AS BIT), EditBlockedReason               = k.EditR,
           CanDelete             = CAST(CASE WHEN k.DeleteR             IS NULL THEN 1 ELSE 0 END AS BIT), DeleteBlockedReason             = k.DeleteR,
           CanRelease            = CAST(CASE WHEN k.ReleaseR            IS NULL THEN 1 ELSE 0 END AS BIT), ReleaseBlockedReason            = k.ReleaseR,
           CanSendForApproval    = CAST(CASE WHEN k.SendForApprovalR    IS NULL THEN 1 ELSE 0 END AS BIT), SendForApprovalBlockedReason    = k.SendForApprovalR,
           CanApprove            = CAST(CASE WHEN k.ApproveR            IS NULL THEN 1 ELSE 0 END AS BIT), ApproveBlockedReason            = k.ApproveR,
           CanReject             = CAST(CASE WHEN k.RejectR             IS NULL THEN 1 ELSE 0 END AS BIT), RejectBlockedReason             = k.RejectR,
           CanWithdraw           = CAST(CASE WHEN k.WithdrawR           IS NULL THEN 1 ELSE 0 END AS BIT), WithdrawBlockedReason           = k.WithdrawR,
           CanBackToDraft        = CAST(CASE WHEN k.BackToDraftR        IS NULL THEN 1 ELSE 0 END AS BIT), BackToDraftBlockedReason        = k.BackToDraftR,
           CanDispatch           = CAST(CASE WHEN k.DispatchR           IS NULL THEN 1 ELSE 0 END AS BIT), DispatchBlockedReason           = k.DispatchR,
           CanReceive            = CAST(CASE WHEN k.ReceiveR            IS NULL THEN 1 ELSE 0 END AS BIT), ReceiveBlockedReason            = k.ReceiveR,
           CanDispatchAndReceive = CAST(CASE WHEN k.DispatchAndReceiveR IS NULL THEN 1 ELSE 0 END AS BIT), DispatchAndReceiveBlockedReason = k.DispatchAndReceiveR,
           CanNothingMoreSent    = CAST(CASE WHEN k.NothingMoreSentR    IS NULL THEN 1 ELSE 0 END AS BIT), NothingMoreSentBlockedReason    = k.NothingMoreSentR,
           CanCancel             = CAST(CASE WHEN k.CancelR             IS NULL THEN 1 ELSE 0 END AS BIT), CancelBlockedReason             = k.CancelR,
           CanCreateReturn       = CAST(CASE WHEN k.CreateReturnR       IS NULL THEN 1 ELSE 0 END AS BIT), CreateReturnBlockedReason       = k.CreateReturnR,
           CanUpdateDetails      = CAST(CASE WHEN k.UpdateDetailsR      IS NULL THEN 1 ELSE 0 END AS BIT), UpdateDetailsBlockedReason      = k.UpdateDetailsR,
           CanEditExpectedArrival = CAST(CASE WHEN ea.Reason IS NULL THEN 1 ELSE 0 END AS BIT), EditExpectedArrivalBlockedReason = ea.Reason,
           -- (91) To's stock levels (active items), the items still below To's Min after this order, Fill to Max and
           --      Add items below Min (fn_TransferOrder_Blocks)
           ToLevelCount          = lc.N,
           ItemsBelowMin         = bm.N,
           CanFillToMax          = CAST(CASE WHEN k.FillToMaxR          IS NULL THEN 1 ELSE 0 END AS BIT), FillToMaxBlockedReason          = k.FillToMaxR,
           CanAddBelowMin        = CAST(CASE WHEN k.AddBelowMinR        IS NULL THEN 1 ELSE 0 END AS BIT), AddBelowMinBlockedReason        = k.AddBelowMinR,
           o.RowVersion
    FROM inventory.TransferOrders o
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = o.DocumentTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = o.BranchId
    INNER JOIN masterdata.Warehouses fw     ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Branches fb       ON fb.Id = fw.BranchId
    INNER JOIN masterdata.Warehouses tw     ON tw.Id = o.ToWarehouseId
    INNER JOIN masterdata.Branches tb       ON tb.Id = tw.BranchId
    LEFT  JOIN inventory.TransferOrders ro  ON ro.Id = o.ReturnOfOrderId
    LEFT  JOIN security.Users rqu ON rqu.Id = o.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = o.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = o.RejectedBy
    LEFT  JOIN security.Users rlu ON rlu.Id = o.ReleasedBy
    LEFT  JOIN security.Users nsu ON nsu.Id = o.NotSentBy
    LEFT  JOIN security.Users cxu ON cxu.Id = o.CancelledBy
    LEFT  JOIN security.Users cu  ON cu.Id  = o.CreatedBy
    LEFT  JOIN security.Users uu  ON uu.Id  = o.UpdatedBy
    OUTER APPLY inventory.fn_TransferOrder_State(o.Id) st
    -- the pieces on the way, at the cost frozen on their dispatch line (information: a transfer moves no cost)
    OUTER APPLY (SELECT Value = ROUND(SUM(CAST(dl.QuantityBase - dl.SettledBase AS DECIMAL(18,6)) * ISNULL(dl.UnitCostBase, 0)), 2)
                 FROM inventory.TransferPostingLines dl
                 INNER JOIN inventory.TransferPostings p ON p.Id = dl.PostingId
                 WHERE p.TransferOrderId = o.Id AND p.Kind = N'Dispatch' AND p.Status = 2 AND dl.QuantityBase > dl.SettledBase) v
    CROSS APPLY (SELECT EditR               = MAX(CASE WHEN a.Action = N'Edit'               THEN a.Message END),
                        DeleteR             = MAX(CASE WHEN a.Action = N'Delete'             THEN a.Message END),
                        ReleaseR            = MAX(CASE WHEN a.Action = N'Release'            THEN a.Message END),
                        SendForApprovalR    = MAX(CASE WHEN a.Action = N'SendForApproval'    THEN a.Message END),
                        ApproveR            = MAX(CASE WHEN a.Action = N'Approve'            THEN a.Message END),
                        RejectR             = MAX(CASE WHEN a.Action = N'Reject'             THEN a.Message END),
                        WithdrawR           = MAX(CASE WHEN a.Action = N'Withdraw'           THEN a.Message END),
                        BackToDraftR        = MAX(CASE WHEN a.Action = N'BackToDraft'        THEN a.Message END),
                        DispatchR           = MAX(CASE WHEN a.Action = N'Dispatch'           THEN a.Message END),
                        ReceiveR            = MAX(CASE WHEN a.Action = N'Receive'            THEN a.Message END),
                        DispatchAndReceiveR = MAX(CASE WHEN a.Action = N'DispatchAndReceive' THEN a.Message END),
                        NothingMoreSentR    = MAX(CASE WHEN a.Action = N'NothingMoreSent'    THEN a.Message END),
                        CancelR             = MAX(CASE WHEN a.Action = N'Cancel'             THEN a.Message END),
                        CreateReturnR       = MAX(CASE WHEN a.Action = N'CreateReturn'       THEN a.Message END),
                        UpdateDetailsR      = MAX(CASE WHEN a.Action = N'UpdateDetails'      THEN a.Message END),
                        FillToMaxR          = MAX(CASE WHEN a.Action = N'FillToMax'          THEN a.Message END),   -- (91)
                        AddBelowMinR        = MAX(CASE WHEN a.Action = N'AddBelowMin'        THEN a.Message END)    -- (91)
                 FROM @B a) k
    -- (T9) Expected arrival and Reference No. stay editable on a released order until it is received or closed
    CROSS APPLY (SELECT Reason = CASE WHEN o.Status = 3 OR st.DisplayStatus IN (N'Received', N'Closed')
                                      THEN N'Only the notes can change on a received, closed or cancelled transfer order.'
                                      ELSE k.UpdateDetailsR END) ea
    -- (91) the levels at To of active items; the items whose line is red (To still below its Min after this order)
    CROSS APPLY (SELECT N = COUNT(*)
                 FROM inventory.ItemWarehouseLevels lv
                 INNER JOIN inventory.Items li ON li.Id = lv.ItemId AND li.IsActive = 1
                 WHERE lv.WarehouseId = o.ToWarehouseId) lc
    CROSS APPLY (SELECT N = COUNT(*)
                 FROM @BT bt
                 INNER JOIN @SP sp ON sp.ItemId = bt.ItemId AND sp.WarehouseId = o.ToWarehouseId
                 WHERE sp.HasLevel = 1 AND sp.ProjectedBase + bt.BringsBase < sp.MinBase) bm
    WHERE o.Id = @Id;

    -- 2: lines, and where From and To stand with transfers (this order left out); (91) To's level for the item, and
    --    where To and From stand WITH this order (what it brings / takes, @BT): the line is red while To stays below its
    --    Min (IsBelowMin, L19), From orange when it goes below its own Min (FromBelowMinAfter)
    SELECT l.Id, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive,
           l.ItemUnitId, UnitName = ut.UnitTypeName, iu.IsBaseUnit, l.Quantity, l.PackingFormula, l.OrderedBase,
           l.DispatchedBase, l.ReceivedBase, l.LostBase, l.NotSentBase,
           ToDispatchBase = CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END,
           OnTheWayBase   = l.DispatchedBase - l.ReceivedBase - l.LostBase,
           l.Notes,
           OnHandFromBase    = ISNULL(pf.OnHandBase, 0),
           CommittedFromBase = ISNULL(pf.OutToDispatchBase, 0),
           AvailableFromBase = CASE WHEN pf.OnHandBase - pf.OutToDispatchBase > 0 THEN pf.OnHandBase - pf.OutToDispatchBase ELSE 0 END,
           OnHandToBase      = ISNULL(pt.OnHandBase, 0),
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0),
           ToHasLevel              = ISNULL(pt.HasLevel, CAST(0 AS BIT)),                                     -- (91)
           ToMinBase               = pt.MinBase,
           ToMaxBase               = pt.MaxBase,
           ToOutToDispatchBase     = ISNULL(pt.OutToDispatchBase, 0),
           ToProjectedBeforeBase   = ISNULL(pt.ProjectedBase, 0),
           ToProjectedAfterBase    = ISNULL(pt.ProjectedBase, 0) + ISNULL(bt.BringsBase, 0),
           IsBelowMin              = CAST(CASE WHEN pt.HasLevel = 1 AND ISNULL(pt.ProjectedBase, 0) + ISNULL(bt.BringsBase, 0) < pt.MinBase
                                               THEN 1 ELSE 0 END AS BIT),
           FromHasLevel            = ISNULL(pf.HasLevel, CAST(0 AS BIT)),
           FromMinBase             = pf.MinBase,
           FromProjectedBeforeBase = ISNULL(pf.ProjectedBase, 0),
           FromAfterBase           = ISNULL(pf.ProjectedBase, 0) - ISNULL(bt.TakesBase, 0),
           FromBelowMinAfter       = CAST(CASE WHEN pf.HasLevel = 1 AND ISNULL(pf.ProjectedBase, 0) - ISNULL(bt.TakesBase, 0) < pf.MinBase
                                               THEN 1 ELSE 0 END AS BIT)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    INNER JOIN inventory.Items i          ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu     ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut    ON ut.Id = iu.UnitTypeId
    LEFT  JOIN @BT bt                     ON bt.ItemId = l.ItemId                                             -- (91)
    -- (91) fn_StockPosition's columns (script 90's fn_TransferPosition's five figures + the warehouse's level), worked
    --      out once above for every item of the order (@SP)
    LEFT  JOIN @SP pf ON pf.ItemId = l.ItemId AND pf.WarehouseId = o.FromWarehouseId
    LEFT  JOIN @SP pt ON pt.ItemId = l.ItemId AND pt.WarehouseId = o.ToWarehouseId
    WHERE l.TransferOrderId = @Id
    ORDER BY l.LineNumber;

    -- 3: dispatches and receipts. Reverse: the order-level answer (Blocks) first, then the posting's own
    --    (fn_TransferPosting_ReverseBlock). Change ETA: the order-level answer, then "a dispatch with goods on the way".
    SELECT p.Id, p.Kind, DocumentTypeCode = pdt.Code, p.DocumentNumber, p.PostingDate, p.Eta, p.ReferenceNo, p.Notes,
           StatusCode = CASE p.Status WHEN 2 THEN N'Posted' ELSE N'Reversed' END,
           p.TransitWarehouseId, TransitWarehouseCode = xw.WarehouseCode, TransitWarehouseName = xw.WarehouseName,
           BranchCode = pb.BranchCode, p.PostedWithId, PostedWithNumber = pw.DocumentNumber,
           p.TotalQuantityBase, p.TotalLostBase,
           OnTheWayBase = ISNULL(w.OnTheWay, 0),
           IsLate = CAST(CASE WHEN p.Kind = N'Dispatch' AND p.Status = 2 AND ISNULL(w.OnTheWay, 0) > 0 AND p.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           p.ValueBase, p.LostValueBase,
           p.PostedAtUtc, PostedByName = pu.FullName,
           p.ReverseDate, p.ReversedAtUtc, ReversedByName = ru.FullName, p.ReverseReason,
           CanReverse   = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ReverseBlockedReason   = r.Reason,
           CanChangeEta = CAST(CASE WHEN e.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ChangeEtaBlockedReason = e.Reason
    FROM inventory.TransferPostings p
    INNER JOIN inventory.DocumentTypes pdt      ON pdt.Id = p.DocumentTypeId
    INNER JOIN masterdata.Branches pb           ON pb.Id = p.BranchId
    LEFT  JOIN masterdata.Warehouses xw         ON xw.Id = p.TransitWarehouseId
    LEFT  JOIN inventory.TransferPostings pw    ON pw.Id = p.PostedWithId
    LEFT  JOIN security.Users pu                ON pu.Id = p.PostedBy
    LEFT  JOIN security.Users ru                ON ru.Id = p.ReversedBy
    -- on the way of a dispatch: its lines' sent - settled while it is posted, 0 once reversed (a receipt: 0)
    OUTER APPLY (SELECT OnTheWay = SUM(dl.QuantityBase - dl.SettledBase)
                 FROM inventory.TransferPostingLines dl
                 WHERE dl.PostingId = p.Id AND p.Kind = N'Dispatch' AND p.Status = 2) w
    OUTER APPLY (SELECT TOP (1) q.Message FROM inventory.fn_TransferPosting_ReverseBlock(p.Id) q
                 WHERE q.Message IS NOT NULL ORDER BY q.Seq) rb
    CROSS APPLY (SELECT Reason = COALESCE(CASE WHEN p.Kind = N'Dispatch' THEN @ReverseDispatch ELSE @ReverseReceipt END, rb.Message)) r
    CROSS APPLY (SELECT Reason = COALESCE(@ChangeEta,
                                          CASE WHEN NOT (p.Kind = N'Dispatch' AND p.Status = 2 AND ISNULL(w.OnTheWay, 0) > 0)
                                               THEN N'Only a dispatch with goods on the way can change its ETA.' END)) e
    WHERE p.TransferOrderId = @Id
    ORDER BY p.PostedAtUtc, p.Id;

    -- 4: their lines
    SELECT pl.Id, pl.PostingId, pl.LineNumber, pl.TransferOrderLineId, OrderLineNumber = ol.LineNumber,
           pl.ItemId, i.ItemCode, i.ItemName,
           pl.QuantityBase, pl.LostBase, pl.LossReasonCode, pl.LossNote, pl.SettledBase,
           OnTheWayBase = CASE WHEN p.Kind = N'Dispatch' AND p.Status = 2 THEN pl.QuantityBase - pl.SettledBase ELSE 0 END,
           pl.DispatchLineId, DispatchNumber = dp.DocumentNumber,
           pl.UnitCostBase, pl.LossUnitCostBase
    FROM inventory.TransferPostingLines pl
    INNER JOIN inventory.TransferPostings p         ON p.Id = pl.PostingId
    INNER JOIN inventory.TransferOrderLines ol      ON ol.Id = pl.TransferOrderLineId
    INNER JOIN inventory.Items i                    ON i.Id = pl.ItemId
    LEFT  JOIN inventory.TransferPostingLines dl    ON dl.Id = pl.DispatchLineId
    LEFT  JOIN inventory.TransferPostings dp        ON dp.Id = dl.PostingId
    WHERE p.TransferOrderId = @Id
    ORDER BY p.PostedAtUtc, p.Id, pl.LineNumber;

    -- 5: audit
    SELECT a.Id, a.PostingId, a.Action, a.Details, a.UserId, UserName = u.FullName, a.AtUtc
    FROM inventory.TransferOrderAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.TransferOrderId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- 6: the returns of this order (new orders in the other direction, 2.3.8.20)
    SELECT r.Id, r.DocumentNumber, r.DocumentDate,
           StatusCode = CASE r.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           rs.DisplayStatus
    FROM inventory.TransferOrders r
    OUTER APPLY inventory.fn_TransferOrder_State(r.Id) rs
    WHERE r.ReturnOfOrderId = @Id
    ORDER BY r.Id;
END
GO

/* (91) WHAT FROM HOLDS AND TO EXPECTS, per item, for a draft's lines: script 90's five figures and refusals (From = To;
   a warehouse missing or On the way: 62000), + To's level and Projected before the draft, From's Projected and Min
   (the names of Get's lines), so the grid shows Min / Max / Projected at {To} on an unsaved draft (3.3.6.2). */
-- Re-created (91) from the body of script 90: + ToInOnTheWayBase, ToInToDispatchBase, ToOutToDispatchBase,
-- ToProjectedBeforeBase, ToHasLevel, ToMinBase, ToMaxBase, FromProjectedBeforeBase, FromHasLevel, FromMinBase.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Availability
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ItemIds         logistics.tvp_IdList READONLY,
    @ExcludeOrderId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @m NVARCHAR(400);
    IF @FromWarehouseId = @ToWarehouseId
        THROW 62000, 'The destination must differ from the source.', 1;
    SELECT TOP (1) @m = CASE WHEN w.Id IS NULL THEN N'The warehouse was not found.'
                             ELSE w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot be chosen.' END
    FROM (VALUES (1, @FromWarehouseId), (2, @ToWarehouseId)) s (Side, WarehouseId)
    LEFT JOIN masterdata.Warehouses w ON w.Id = s.WarehouseId
    WHERE w.Id IS NULL OR w.IsTransit = 1
    ORDER BY s.Side;
    IF @m IS NOT NULL THROW 62000, @m, 1;

    SELECT ItemId            = x.Id,
           OnHandFromBase    = ISNULL(pf.OnHandBase, 0),
           CommittedFromBase = ISNULL(pf.OutToDispatchBase, 0),
           AvailableFromBase = CASE WHEN pf.OnHandBase - pf.OutToDispatchBase > 0 THEN pf.OnHandBase - pf.OutToDispatchBase ELSE 0 END,
           OnHandToBase      = ISNULL(pt.OnHandBase, 0),
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0),
           -- (91) To's level and where To and From stand without the draft (the page adds the form's Ordered): the names are Get's
           ToInOnTheWayBase        = ISNULL(pt.InOnTheWayBase, 0),
           ToInToDispatchBase      = ISNULL(pt.InToDispatchBase, 0),
           ToOutToDispatchBase     = ISNULL(pt.OutToDispatchBase, 0),
           ToProjectedBeforeBase   = ISNULL(pt.ProjectedBase, 0),
           ToHasLevel              = ISNULL(pt.HasLevel, CAST(0 AS BIT)),
           ToMinBase               = pt.MinBase,
           ToMaxBase               = pt.MaxBase,
           FromProjectedBeforeBase = ISNULL(pf.ProjectedBase, 0),
           FromHasLevel            = ISNULL(pf.HasLevel, CAST(0 AS BIT)),
           FromMinBase             = pf.MinBase
    FROM @ItemIds x
    -- (91) fn_StockPosition = script 90's fn_TransferPosition (the same five figures) + the warehouse's level
    OUTER APPLY inventory.fn_StockPosition(x.Id, @FromWarehouseId, @ExcludeOrderId) pf
    OUTER APPLY inventory.fn_StockPosition(x.Id, @ToWarehouseId, @ExcludeOrderId) pt
    ORDER BY x.Id;
END
GO

/* (91) FILL TO MAX (@AddItems empty) AND ADD ITEMS BELOW MIN (@AddItems = the drawer's ticked items), on a SAVED draft
   (business-context 4.14, 3.4.3; the rule is inventory.fn_TransferFill_Plan's). @Apply = 0: a preview, no lock,
   nothing written. @Apply = 1: the order WITH (UPDLOCK, HOLDLOCK) and its RowVersion (62004; none sent: 62000), the plan worked out
   again, then Fill SETS the first line of each filled item (Ordered = the units, the unit's current packing formula),
   Add inserts one line per filled item at the end (line numbers in item code order), the order's totals follow, and
   one audit row (FillToMax / ItemsAddedBelowMin) is written. Nothing to change: no line and no header is written (the
   RowVersion stays valid), only the audit row. The refusals are fn_TransferOrder_Blocks' FillToMax / AddBelowMin
   rows. Result 1: the summary and the sentence. Result 2: the plan, in item code order (Add after an apply: the new
   line numbers). Result 3: the warnings (From below its own Min; other drafts or waiting orders to To holding the same
   items: L10). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_FillToMax
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @AddItems   inventory.tvp_TransferFillItem READONLY,
    @Apply      BIT       = 0,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Apply = ISNULL(@Apply, 0);

    DECLARE @Mode NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @AddItems) THEN N'Add' ELSE N'Fill' END;
    DECLARE @ErrNo INT, @Msg NVARCHAR(400), @FromId INT, @ToId INT, @FromCode NVARCHAR(20), @ToCode NVARCHAR(20),
            @Message NVARCHAR(500), @Filled INT, @Capped INT, @Changed INT, @AtOrAboveMin INT, @NoLevel INT,
            @Covered INT, @Inactive INT, @OnOrder INT, @NotFilled INT, @MaxLine INT;
    DECLARE @c inventory.tvp_TransferFillCandidate;
    DECLARE @PlanItems logistics.tvp_IdList;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(500) NOT NULL);

    -- 0. The order; an apply is made with the RowVersion the page read (L9): without one it could overwrite a change
    --    it never saw
    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id) THROW 62006, 'Transfer order not found.', 1;
    IF @Apply = 1 AND @RowVersion IS NULL THROW 62000, 'The row version is missing. Reload the page and try again.', 1;

    BEGIN TRY
        -- 1. Apply: the order locked until the commit, and the RowVersion the page read. A preview reads without a lock.
        IF @Apply = 1
        BEGIN
            BEGIN TRANSACTION;
            SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId
            FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @FromId IS NULL THROW 62006, 'Transfer order not found.', 1;
            IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;
        END
        ELSE
            SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId FROM inventory.TransferOrders WHERE Id = @Id;

        SELECT @FromCode = WarehouseCode FROM masterdata.Warehouses WHERE Id = @FromId;
        SELECT @ToCode   = WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToId;

        -- 2. Why it cannot be done now (a draft, the TRO type on, fit warehouses, lines, levels at To)
        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = CASE @Mode WHEN N'Add' THEN N'AddBelowMin' ELSE N'FillToMax' END AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        -- 3. The candidates
        IF @Mode = N'Fill'
            -- one per item of the order: its lowest-numbered line, the other lines of the item counted in OtherLinesBase
            INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
            SELECT ROW_NUMBER() OVER (ORDER BY f.LineNumber), f.ItemId, f.ItemUnitId, iu.PackingFormula, f.Id, f.LineNumber,
                   f.Quantity, f.OrderedBase, f.ItemBase - f.OrderedBase, 0
            FROM (SELECT l.Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, l.OrderedBase,
                         ItemBase = SUM(l.OrderedBase) OVER (PARTITION BY l.ItemId),
                         Rn       = ROW_NUMBER() OVER (PARTITION BY l.ItemId ORDER BY l.LineNumber)
                  FROM inventory.TransferOrderLines l
                  WHERE l.TransferOrderId = @Id) f
            INNER JOIN inventory.ItemUnits iu ON iu.Id = f.ItemUnitId
            WHERE f.Rn = 1;
        ELSE
        BEGIN
            -- one per ticked item, in the unit given (it must be the item's) or its base unit; an item already on the order
            -- (OnOrder, skipped) counts the order's lines of it in OtherLinesBase, as the drawer does, so its figures after
            -- this order are Get's
            SELECT TOP (1) @Msg = CASE WHEN i.Id IS NULL THEN N'Item not found.'
                                       ELSE N'The unit does not belong to item ' + i.ItemCode + N'.' END
            FROM @AddItems a
            LEFT JOIN inventory.Items i      ON i.Id = a.ItemId
            LEFT JOIN inventory.ItemUnits iu ON iu.Id = a.ItemUnitId AND iu.ItemId = a.ItemId
            WHERE i.Id IS NULL OR (a.ItemUnitId IS NOT NULL AND iu.Id IS NULL)
            ORDER BY CASE WHEN i.Id IS NULL THEN 0 ELSE 1 END, i.ItemCode;
            IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

            INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
            SELECT ROW_NUMBER() OVER (ORDER BY i.ItemCode), a.ItemId, u.Id, u.PackingFormula, NULL, NULL, NULL, NULL,
                   ISNULL(ol.Pcs, 0),
                   CASE WHEN ol.N > 0 THEN 1 ELSE 0 END
            FROM @AddItems a
            INNER JOIN inventory.Items i ON i.Id = a.ItemId
            CROSS APPLY (SELECT N = COUNT(*), Pcs = SUM(l.OrderedBase)
                         FROM inventory.TransferOrderLines l
                         WHERE l.TransferOrderId = @Id AND l.ItemId = a.ItemId) ol
            CROSS APPLY (SELECT TOP (1) iu.Id, iu.PackingFormula
                         FROM inventory.ItemUnits iu
                         WHERE iu.ItemId = a.ItemId AND (iu.Id = a.ItemUnitId OR a.ItemUnitId IS NULL)
                         ORDER BY CASE WHEN iu.Id = a.ItemUnitId THEN 0 ELSE 1 END, iu.IsBaseUnit DESC, iu.PackingFormula, iu.Id) u;
        END

        -- 4. The plan, with the figures after this order
        SELECT p.Seq, p.ItemId, p.ItemCode, p.ItemName, p.ItemIsActive, p.ItemUnitId, UnitName = ut.UnitTypeName, p.PackingFormula,
               p.LineId, p.LineNumber, p.CurrentQuantity, p.CurrentQuantityBase, p.OtherLinesBase, p.OnOrder,
               p.ToOnHandBase, p.ToInOnTheWayBase, p.ToInToDispatchBase, p.ToOutToDispatchBase, p.ProjectedBeforeBase,
               p.ToHasLevel, p.MinBase, p.MaxBase, p.FromOnHandBase, p.FromCommittedBase, p.AvailableFromBase, p.AvailableForLineBase,
               p.NeedBase, p.UnitsNeeded, p.UnitsAvailable, p.Outcome, p.NewQuantity, p.NewQuantityBase, p.IsCapped,
               p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase,
               ProjectedAfterBase = p.ProjectedBeforeBase + p.OtherLinesBase + COALESCE(p.NewQuantityBase, p.CurrentQuantityBase, 0),
               FromAfterBase      = p.FromProjectedBeforeBase - (p.OtherLinesBase + COALESCE(p.NewQuantityBase, p.CurrentQuantityBase, 0)),
               FromBelowMinAfter  = CAST(CASE WHEN p.FromHasLevel = 1
                                               AND p.FromProjectedBeforeBase - (p.OtherLinesBase + COALESCE(p.NewQuantityBase, p.CurrentQuantityBase, 0)) < p.FromMinBase
                                              THEN 1 ELSE 0 END AS BIT),
               -- a filled line whose Ordered changes (in its unit, or in pcs when the unit's packing changed since it was saved)
               IsChanged          = CAST(CASE WHEN p.Outcome = N'Filled'
                                               AND (p.NewQuantity <> ISNULL(p.CurrentQuantity, 0) OR p.NewQuantityBase <> ISNULL(p.CurrentQuantityBase, 0))
                                              THEN 1 ELSE 0 END AS BIT),
               PurchasesToComeBase = CAST(NULL AS INT),
               NewLineNumber       = CAST(NULL AS INT)
        INTO #plan
        FROM inventory.fn_TransferFill_Plan(@FromId, @ToId, @Id, @c) p
        INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
        INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
        OPTION (RECOMPILE);   -- the candidates' real count: a drawer's 2,000 items read the history once, not per item

        -- what purchase orders and containers still bring to To, shown dimmed (not counted, L11): a preview only
        IF @Apply = 0
            UPDATE p
            SET PurchasesToComeBase = pc.Pcs
            FROM #plan p
            CROSS APPLY (SELECT Pcs = s.TransitBase + s.OutstandingOrderBase
                         FROM inventory.fn_Shortage_Live(@ToId, 1) s
                         WHERE s.ItemId = p.ItemId) pc;

        SELECT @Filled       = ISNULL(SUM(CASE WHEN Outcome = N'Filled' THEN 1 ELSE 0 END), 0),
               @Capped       = ISNULL(SUM(CASE WHEN IsCapped = 1 THEN 1 ELSE 0 END), 0),
               @Changed      = ISNULL(SUM(CASE WHEN IsChanged = 1 THEN 1 ELSE 0 END), 0),
               @AtOrAboveMin = ISNULL(SUM(CASE WHEN Outcome = N'AtOrAboveMin' THEN 1 ELSE 0 END), 0),
               @NoLevel      = ISNULL(SUM(CASE WHEN Outcome = N'NoLevel' THEN 1 ELSE 0 END), 0),
               @Covered      = ISNULL(SUM(CASE WHEN Outcome = N'Covered' THEN 1 ELSE 0 END), 0),
               @Inactive     = ISNULL(SUM(CASE WHEN Outcome = N'Inactive' THEN 1 ELSE 0 END), 0),
               @OnOrder      = ISNULL(SUM(CASE WHEN Outcome = N'OnOrder' THEN 1 ELSE 0 END), 0),
               @NotFilled    = ISNULL(SUM(CASE WHEN Outcome = N'NothingAvailable' THEN 1 ELSE 0 END), 0)
        FROM #plan;

        SET @Message = inventory.fn_TransferFill_Message(@Mode, @FromCode, @ToCode, @Filled, @Capped, @AtOrAboveMin, @NoLevel,
                                                         @Covered, @Inactive, @OnOrder, @NotFilled,
                                                         CASE WHEN @Apply = 1 AND @Filled > 0 AND @Changed = 0 THEN 1 ELSE 0 END);

        -- 5. The warnings: From below its own Min after this order, per filled item; other drafts / waiting orders to To
        --    holding the plan's items (fn_TransferFill_FromWarning, fn_TransferFill_OtherOrdersWarning)
        INSERT INTO @W (Message)
        SELECT inventory.fn_TransferFill_FromWarning(@FromCode, p.ItemCode, p.FromAfterBase, p.FromMinBase)
        FROM #plan p
        WHERE p.Outcome = N'Filled' AND p.FromBelowMinAfter = 1
        ORDER BY p.ItemCode, p.Seq;

        INSERT INTO @PlanItems (Id) SELECT DISTINCT p.ItemId FROM #plan p;
        INSERT INTO @W (Message)
        SELECT w.Message FROM inventory.fn_TransferFill_OtherOrdersWarning(@ToId, @ToCode, @Id, @PlanItems) w;

        -- 6. Apply
        IF @Apply = 1
        BEGIN
            IF @Changed > 0
            BEGIN
                IF @Mode = N'Fill'
                    UPDATE l
                    SET Quantity = p.NewQuantity, PackingFormula = p.PackingFormula
                    FROM inventory.TransferOrderLines l
                    INNER JOIN #plan p ON p.LineId = l.Id
                    WHERE l.TransferOrderId = @Id AND p.IsChanged = 1;
                ELSE
                BEGIN
                    SET @MaxLine = ISNULL((SELECT MAX(LineNumber) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id), 0);

                    UPDATE p
                    SET NewLineNumber = @MaxLine + x.Rn
                    FROM #plan p
                    INNER JOIN (SELECT Seq, Rn = ROW_NUMBER() OVER (ORDER BY ItemCode, Seq) FROM #plan WHERE IsChanged = 1) x ON x.Seq = p.Seq;

                    INSERT INTO inventory.TransferOrderLines (TransferOrderId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, Notes)
                    SELECT @Id, p.NewLineNumber, p.ItemId, p.ItemUnitId, p.NewQuantity, p.PackingFormula, NULL
                    FROM #plan p
                    WHERE p.IsChanged = 1;
                END

                UPDATE o
                SET TotalLines       = t.N,
                    TotalOrderedBase = t.Pcs,
                    UpdatedAtUtc     = SYSUTCDATETIME(),
                    UpdatedBy        = @UserId
                FROM inventory.TransferOrders o
                CROSS APPLY (SELECT N = COUNT(*), Pcs = ISNULL(SUM(l.OrderedBase), 0)
                             FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = o.Id) t
                WHERE o.Id = @Id;
            END

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, CASE @Mode WHEN N'Add' THEN N'ItemsAddedBelowMin' ELSE N'FillToMax' END, LEFT(@Message, 500), @UserId);

            COMMIT TRANSACTION;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- 7. The answer
    -- 1: the summary
    SELECT Mode = @Mode, Applied = @Apply, Message = @Message,
           Filled = @Filled, Capped = @Capped, Changed = @Changed, AtOrAboveMin = @AtOrAboveMin, NoLevel = @NoLevel,
           Covered = @Covered, Inactive = @Inactive, OnOrder = @OnOrder, NotFilled = @NotFilled;

    -- 2: the plan, in item code order: the plan's own columns (fn_TransferFill_Plan: ProjectedBeforeBase, MinBase,
    --    MaxBase) + ProjectedAfterBase (spec 3.3.6.3); the API maps them to TransferFillResult.lines' to... names.
    SELECT p.Seq, p.ItemId, p.ItemCode, p.ItemName, p.ItemIsActive,
           p.LineId, LineNumber = COALESCE(p.NewLineNumber, p.LineNumber),
           p.ItemUnitId, p.UnitName, p.PackingFormula,
           p.CurrentQuantity, p.CurrentQuantityBase, p.NewQuantity, p.NewQuantityBase, p.OtherLinesBase, p.OnOrder,
           p.ToOnHandBase, p.ToInOnTheWayBase, p.ToInToDispatchBase, p.ToOutToDispatchBase,
           p.ProjectedBeforeBase, p.ProjectedAfterBase,
           p.ToHasLevel, p.MinBase, p.MaxBase,
           p.NeedBase, p.UnitsNeeded, p.UnitsAvailable,
           p.FromOnHandBase, p.FromCommittedBase, p.AvailableFromBase, p.AvailableForLineBase,
           p.Outcome, p.IsCapped, p.IsChanged,
           p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase, p.FromAfterBase, p.FromBelowMinAfter,
           p.PurchasesToComeBase
    FROM #plan p
    ORDER BY p.ItemCode, p.Seq;

    -- 3: the warnings
    SELECT w.Message FROM @W w ORDER BY w.Seq;
END
GO

/* (91) THE "ADD ITEMS BELOW MIN" DRAWER: every level at the order's To for an ACTIVE item (+ the filters), each item in
   each of its units, planned by inventory.fn_TransferFill_Plan (positions once per item; OtherLinesBase = what the
   order already holds of the item). Result 1, per item: where To stands, Min / Max, Need, what From has available;
   IsBelowMin counts the order's own lines for an item on it (an item the order covers is not "below Min"); with
   @OnlyBelowMin only those. Result 2, per item and unit: the proposal (Filled, else why not). The same refusals as
   Add items below Min (fn_TransferOrder_Blocks, AddBelowMin). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_BelowMinCandidates
    @Id           INT,
    @Search       NVARCHAR(100) = NULL,
    @ItemFamilyId INT           = NULL,
    @BrandId      INT           = NULL,
    @OnlyBelowMin BIT           = 1,
    @UserId       INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @OnlyBelowMin = ISNULL(@OnlyBelowMin, 1);

    DECLARE @ErrNo INT, @Msg NVARCHAR(400), @FromId INT, @ToId INT;
    DECLARE @c inventory.tvp_TransferFillCandidate;

    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id) THROW 62006, 'Transfer order not found.', 1;

    SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
    FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
    WHERE b.Action = N'AddBelowMin' AND b.Message IS NOT NULL
    ORDER BY b.Seq;
    IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

    SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId FROM inventory.TransferOrders WHERE Id = @Id;

    INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
    SELECT ROW_NUMBER() OVER (ORDER BY i.ItemCode, u.IsBaseUnit DESC, u.PackingFormula, u.Id),
           i.Id, u.Id, u.PackingFormula, NULL, NULL, NULL, NULL,
           ISNULL(ol.Pcs, 0),
           CASE WHEN ol.N > 0 THEN 1 ELSE 0 END
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN inventory.Items i     ON i.Id = lv.ItemId AND i.IsActive = 1
    INNER JOIN inventory.ItemUnits u ON u.ItemId = i.Id
    CROSS APPLY (SELECT N = COUNT(*), Pcs = SUM(l.OrderedBase)
                 FROM inventory.TransferOrderLines l
                 WHERE l.TransferOrderId = @Id AND l.ItemId = i.Id) ol
    WHERE lv.WarehouseId = @ToId
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits bu WHERE bu.ItemId = i.Id AND bu.Barcode = @Search));

    SELECT p.*, IsBaseUnit = iu.IsBaseUnit, UnitName = ut.UnitTypeName,
           FromBelowMinAfter = CAST(CASE WHEN p.FromHasLevel = 1
                                          AND p.FromProjectedBeforeBase - (p.OtherLinesBase + ISNULL(p.NewQuantityBase, 0)) < p.FromMinBase
                                         THEN 1 ELSE 0 END AS BIT)
    INTO #plan
    FROM inventory.fn_TransferFill_Plan(@FromId, @ToId, @Id, @c) p
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    OPTION (RECOMPILE);   -- the candidates' real count (every level at To): the history is read once, not per item

    SELECT p.ItemId, p.ItemCode, p.ItemName, p.ToOnHandBase, p.ToInOnTheWayBase, p.ToInToDispatchBase, p.ToOutToDispatchBase,
           p.ProjectedBeforeBase, p.OtherLinesBase, p.MinBase, p.MaxBase, p.NeedBase, p.AvailableFromBase, p.OnOrder,
           p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase,
           IsBelowMin = CAST(CASE WHEN p.OnOrder = 1 THEN CASE WHEN p.ProjectedBeforeBase + p.OtherLinesBase < p.MinBase THEN 1 ELSE 0 END
                                  ELSE CASE WHEN p.ProjectedBeforeBase < p.MinBase THEN 1 ELSE 0 END END AS BIT)
    INTO #items
    FROM (SELECT x.*, Rn = ROW_NUMBER() OVER (PARTITION BY x.ItemId ORDER BY x.Seq) FROM #plan x) p
    WHERE p.Rn = 1;

    -- 1: per item, the columns of spec 3.3.6.4 (ProjectedBeforeBase, MinBase, MaxBase: the plan's names; the API maps
    --    them to TransferBelowMinResult.items' to... names) + OtherLinesBase.
    SELECT x.ItemId, x.ItemCode, x.ItemName, FamilyName = f.FamilyName, b.BrandName,
           BaseUnitId = bu.Id, BaseUnitName = but.UnitTypeName,
           x.ToOnHandBase, x.ToInOnTheWayBase, x.ToInToDispatchBase, x.ToOutToDispatchBase,
           x.ProjectedBeforeBase, x.MinBase, x.MaxBase,
           x.NeedBase, x.AvailableFromBase, x.IsBelowMin, x.OnOrder, x.OtherLinesBase,
           x.FromHasLevel, x.FromMinBase, x.FromProjectedBeforeBase
    FROM #items x
    INNER JOIN inventory.Items i          ON i.Id = x.ItemId
    LEFT  JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b        ON b.Id = i.BrandId
    OUTER APPLY (SELECT TOP (1) u.Id, u.UnitTypeId FROM inventory.ItemUnits u
                 WHERE u.ItemId = x.ItemId ORDER BY u.IsBaseUnit DESC, u.PackingFormula, u.Id) bu
    LEFT  JOIN masterdata.UnitTypes but   ON but.Id = bu.UnitTypeId
    WHERE @OnlyBelowMin = 0 OR x.IsBelowMin = 1
    ORDER BY x.NeedBase DESC, x.ItemCode;

    -- 2: per item and unit, the proposal
    SELECT p.ItemId, p.ItemUnitId, p.UnitName, p.PackingFormula, p.IsBaseUnit,
           ProposedQuantity = p.NewQuantity, ProposedBase = p.NewQuantityBase, p.IsCapped, p.Outcome, p.FromBelowMinAfter
    FROM #plan p
    INNER JOIN #items x ON x.ItemId = p.ItemId
    WHERE @OnlyBelowMin = 0 OR x.IsBelowMin = 1
    ORDER BY p.ItemCode, p.Seq;
END
GO

/* (91) "CREATE TRANSFER ORDER..." FROM TICKED ROWS OF STOCK LEVELS (L14, S14): one destination, From chosen by the user;
   each ticked item in its base unit, planned as Add items below Min (no order yet: nothing excluded, no other lines);
   nothing filled: nothing created (62009, the sentence says why). The draft is saved by script 90's
   usp_TransferOrder_Save, which runs its own transaction and checks (none is opened around it): the number is given by
   Save as for any draft (NULL while TRO is numbered at release). Result 1: NewId, DocumentNumber, Message. Result 2: the
   warnings of Fill to Max for the new draft (From below its own Min; other drafts or waiting orders to To holding its
   items, L10). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_CreateFromLevels
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ItemIds         logistics.tvp_IdList READONLY,
    @DocumentDate    DATE = NULL,
    @ExpectedArrival DATE = NULL,
    @UserId          INT  = NULL,
    @NewId           INT  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @FromCode NVARCHAR(20), @ToCode NVARCHAR(20), @Number NVARCHAR(30), @Notes NVARCHAR(1000),
            @AddMessage NVARCHAR(500), @Filled INT, @Capped INT, @AtOrAboveMin INT, @NoLevel INT, @Covered INT,
            @Inactive INT, @OnOrder INT, @NotFilled INT;
    DECLARE @c inventory.tvp_TransferFillCandidate;
    DECLARE @Lines inventory.tvp_TransferOrderLine;
    DECLARE @FilledItems logistics.tvp_IdList;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(500) NOT NULL);

    SET @NewId = NULL;
    SET @DocumentDate = ISNULL(@DocumentDate, CAST(SYSUTCDATETIME() AS DATE));

    EXEC inventory.usp_TransferOrder_CheckWarehouses @FromWarehouseId, @ToWarehouseId;

    IF NOT EXISTS (SELECT 1 FROM @ItemIds) THROW 62009, 'Tick at least one item.', 1;
    IF EXISTS (SELECT 1 FROM @ItemIds x WHERE NOT EXISTS (SELECT 1 FROM inventory.Items i WHERE i.Id = x.Id))
        THROW 62000, 'Item not found.', 1;

    SELECT @FromCode = WarehouseCode FROM masterdata.Warehouses WHERE Id = @FromWarehouseId;
    SELECT @ToCode   = WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToWarehouseId;

    INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
    SELECT ROW_NUMBER() OVER (ORDER BY i.ItemCode), i.Id, u.Id, u.PackingFormula, NULL, NULL, NULL, NULL, 0, 0
    FROM @ItemIds x
    INNER JOIN inventory.Items i ON i.Id = x.Id
    CROSS APPLY (SELECT TOP (1) iu.Id, iu.PackingFormula FROM inventory.ItemUnits iu
                 WHERE iu.ItemId = i.Id ORDER BY iu.IsBaseUnit DESC, iu.PackingFormula, iu.Id) u;

    SELECT p.Seq, p.ItemId, p.ItemCode, p.ItemUnitId, p.Outcome, p.NewQuantity, p.NewQuantityBase, p.IsCapped,
           p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase
    INTO #plan
    FROM inventory.fn_TransferFill_Plan(@FromWarehouseId, @ToWarehouseId, NULL, @c) p
    OPTION (RECOMPILE);

    SELECT @Filled       = ISNULL(SUM(CASE WHEN Outcome = N'Filled' THEN 1 ELSE 0 END), 0),
           @Capped       = ISNULL(SUM(CASE WHEN IsCapped = 1 THEN 1 ELSE 0 END), 0),
           @AtOrAboveMin = ISNULL(SUM(CASE WHEN Outcome = N'AtOrAboveMin' THEN 1 ELSE 0 END), 0),
           @NoLevel      = ISNULL(SUM(CASE WHEN Outcome = N'NoLevel' THEN 1 ELSE 0 END), 0),
           @Covered      = ISNULL(SUM(CASE WHEN Outcome = N'Covered' THEN 1 ELSE 0 END), 0),
           @Inactive     = ISNULL(SUM(CASE WHEN Outcome = N'Inactive' THEN 1 ELSE 0 END), 0),
           @OnOrder      = ISNULL(SUM(CASE WHEN Outcome = N'OnOrder' THEN 1 ELSE 0 END), 0),
           @NotFilled    = ISNULL(SUM(CASE WHEN Outcome = N'NothingAvailable' THEN 1 ELSE 0 END), 0)
    FROM #plan;

    IF @Filled = 0
    BEGIN
        SET @Msg = CASE WHEN @NotFilled > 0
                        THEN N'Nothing to transfer: ' + ISNULL(@FromCode, N'the source') + N' has none of these items available.'
                        ELSE N'Nothing to transfer: none of these items is below its Min at ' + ISNULL(@ToCode, N'the destination') + N'.' END;
        THROW 62009, @Msg, 1;
    END

    SET @AddMessage = inventory.fn_TransferFill_Message(N'Add', @FromCode, @ToCode, @Filled, @Capped, @AtOrAboveMin, @NoLevel,
                                                        @Covered, @Inactive, @OnOrder, @NotFilled, 0);

    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, Quantity, Notes)
    SELECT ROW_NUMBER() OVER (ORDER BY p.ItemCode, p.Seq), p.ItemId, p.ItemUnitId, p.NewQuantity, NULL
    FROM #plan p
    WHERE p.Outcome = N'Filled';

    SET @Notes = N'Created from Inventory ' + NCHAR(8250) + N' Stock Levels: items below Min at ' + ISNULL(@ToCode, N'the destination') + N'.';

    EXEC inventory.usp_TransferOrder_Save
         @Id              = NULL,
         @DocumentDate    = @DocumentDate,
         @FromWarehouseId = @FromWarehouseId,
         @ToWarehouseId   = @ToWarehouseId,
         @ExpectedArrival = @ExpectedArrival,
         @ReferenceNo     = NULL,
         @Notes           = @Notes,
         @Lines           = @Lines,
         @RowVersion      = NULL,
         @UserId          = @UserId,
         @NewId           = @NewId OUTPUT;

    SELECT @Number = DocumentNumber FROM inventory.TransferOrders WHERE Id = @NewId;

    -- 1: the draft and the sentence
    SELECT NewId = @NewId, DocumentNumber = @Number,
           Message = COALESCE(@Number, N'Draft transfer order #' + CAST(@NewId AS NVARCHAR(12))) + N' created. ' + @AddMessage;

    -- 2: the warnings of Fill to Max (3.3.6.3 step 5) for the draft just made: From below its own Min for a filled
    --    item; other drafts or waiting orders to To that already hold its items (a second click makes a second draft
    --    for the same shortage: it is said)
    INSERT INTO @W (Message)
    SELECT inventory.fn_TransferFill_FromWarning(@FromCode, p.ItemCode, p.FromProjectedBeforeBase - p.NewQuantityBase, p.FromMinBase)
    FROM #plan p
    WHERE p.Outcome = N'Filled' AND p.FromHasLevel = 1 AND p.FromProjectedBeforeBase - p.NewQuantityBase < p.FromMinBase
    ORDER BY p.ItemCode, p.Seq;

    INSERT INTO @FilledItems (Id) SELECT DISTINCT p.ItemId FROM #plan p WHERE p.Outcome = N'Filled';
    INSERT INTO @W (Message)
    SELECT w.Message FROM inventory.fn_TransferFill_OtherOrdersWarning(@ToWarehouseId, @ToCode, @NewId, @FilledItems) w;

    SELECT w.Message FROM @W w ORDER BY w.Seq;
END
GO

/* ================================================================== 9. Dashboard: warehouse levels below Min (L3) */

-- (91) THE DASHBOARD'S "WAREHOUSE LEVELS BELOW MIN": the levels of active items at active warehouses (of the branch, or
--      of the company) whose Projected stock is below their Min - the Stock Levels page's "Below Min" tile for the same
--      branch with its default filters (test g), worked out the same set-based way. Read by the API after the summary
--      and the charts, only for a reader who may see it (View Items and View Stock Levels); the summary procedure is not
--      touched.
CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_StockLevels
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- The levels counted: active items at active warehouses of the branch (or the company)
    CREATE TABLE #lv (ItemId INT NOT NULL, WarehouseId INT NOT NULL, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL,
                      PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #lv (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
    SELECT lv.ItemId, lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN inventory.Items i       ON i.Id = lv.ItemId AND i.IsActive = 1
    INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId AND w.IsActive = 1
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId;

    -- What released transfer orders bring and take, every pair at once (fn_TransferPositions, as Stock Levels reads it)
    CREATE TABLE #tp (ItemId INT NOT NULL, WarehouseId INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL,
                      OutToDispatchBase INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #tp (ItemId, WarehouseId, InOnTheWayBase, InToDispatchBase, OutToDispatchBase)
    SELECT tp.ItemId, tp.WarehouseId, tp.InOnTheWayBase, tp.InToDispatchBase, tp.OutToDispatchBase
    FROM inventory.fn_TransferPositions(NULL) tp
    WHERE EXISTS (SELECT 1 FROM #lv lv WHERE lv.ItemId = tp.ItemId AND lv.WarehouseId = tp.WarehouseId);

    SELECT BelowWarehouseMin = COUNT(*)
    FROM #lv lv
    LEFT JOIN #tp tp ON tp.ItemId = lv.ItemId AND tp.WarehouseId = lv.WarehouseId
    LEFT JOIN (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
               FROM inventory.StockMovements m
               INNER JOIN #lv x ON x.ItemId = m.ItemId AND x.WarehouseId = m.WarehouseId
               GROUP BY m.ItemId, m.WarehouseId) oh ON oh.ItemId = lv.ItemId AND oh.WarehouseId = lv.WarehouseId
    CROSS APPLY inventory.fn_StockLevelState(ISNULL(oh.Qty, 0), ISNULL(tp.InOnTheWayBase, 0), ISNULL(tp.InToDispatchBase, 0),
                                             ISNULL(tp.OutToDispatchBase, 0), lv.MinQuantityBase, lv.MaxQuantityBase) st
    WHERE st.Status = N'BelowMin';
END
GO

/* ================================================================== 10. Permissions: View and Edit Stock Levels */

/* (91) TWO PERMISSIONS, with the texts of PermissionCatalog.cs. GRANTED ONCE, when each is first created (script 75's
   pattern: the MERGE's OUTPUT says which rows it inserted, M2), to the system roles and to the roles holding
     inventory.stocklevels.view   View items  (inventory.items.view)
     inventory.stocklevels.edit   Edit items  (inventory.items.edit)
   so nobody gains a power they lack (L15). A role unticked afterwards on Role Permissions is never re-granted; the
   start-up sync of the catalog keeps the texts and gives every permission to the system roles. */
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE (Action NVARCHAR(10) NOT NULL, PermissionId INT NOT NULL, Code NVARCHAR(100) NOT NULL);

    MERGE security.Permissions AS target
    USING
    (
        VALUES
            (N'inventory.stocklevels.view', N'View Stock Levels', N'Inventory',
             N'Open Inventory ' + NCHAR(8250) + N' Stock Levels and the Stock levels per warehouse card of Item Definition: each warehouse''s Min / Max, its stock and what released transfer orders bring or take.', 432),
            (N'inventory.stocklevels.edit', N'Edit Stock Levels', N'Inventory',
             N'Set, change and remove an item''s Min / Max in a warehouse, by hand or from an Excel file.', 434)
    ) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder)
    OUTPUT $action, inserted.Id, inserted.Code INTO @Changed (Action, PermissionId, Code);

    IF EXISTS (SELECT 1 FROM @Changed WHERE Action = N'INSERT')
    BEGIN
        DECLARE @From TABLE (Code NVARCHAR(100) NOT NULL, FromCode NVARCHAR(100) NOT NULL);
        INSERT INTO @From (Code, FromCode) VALUES
            (N'inventory.stocklevels.view', N'inventory.items.view'),
            (N'inventory.stocklevels.edit', N'inventory.items.edit');

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT DISTINCT r.Id, c.PermissionId
        FROM @Changed c
        INNER JOIN @From f ON f.Code = c.Code
        CROSS JOIN security.Roles r
        WHERE c.Action = N'INSERT'
          AND (r.IsSystem = 1
               OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                          WHERE rp.RoleId = r.Id AND p.Code = f.FromCode))
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = c.PermissionId);

        DECLARE @Grants INT = @@ROWCOUNT;
        DECLARE @Created INT = (SELECT COUNT(*) FROM @Changed WHERE Action = N'INSERT');
        PRINT 'Stock level permissions created: ' + CAST(@Created AS NVARCHAR(10))
              + ', granted once: ' + CAST(@Grants AS NVARCHAR(10)) + ' role grant(s).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

/* ================================================================== 11. Check */

-- 1. The objects of script 91 (expected: none MISSING): the two tables, the four table types, the functions, the seven
--    level procedures, Fill to Max, the drawer, Create transfer order and the Dashboard's procedure.
SELECT o.ObjectName,
       ObjectType = ISNULL(so.type_desc, CASE WHEN TYPE_ID(o.ObjectName) IS NOT NULL THEN N'TABLE_TYPE' ELSE N'MISSING' END)
FROM (VALUES (N'inventory.ItemWarehouseLevels'), (N'inventory.ItemWarehouseLevelAudit'),
             (N'inventory.tvp_ItemWarehouseLevel'), (N'inventory.tvp_ItemWarehouseLevelImport'),
             (N'inventory.tvp_TransferFillItem'), (N'inventory.tvp_TransferFillCandidate'),
             (N'masterdata.fn_Warehouse_IsUsedInTransactions'), (N'masterdata.fn_Warehouse_IsUsed'),
             (N'inventory.fn_StockLevelState'), (N'inventory.fn_TransferPositions'),
             (N'inventory.fn_StockPosition'), (N'inventory.fn_TransferFill_Plan'), (N'inventory.fn_TransferFill_Message'),
             (N'inventory.fn_TransferFill_FromWarning'), (N'inventory.fn_TransferFill_OtherOrdersWarning'),
             (N'inventory.fn_ItemWarehouseLevel_ImportJudge'), (N'inventory.fn_TransferOrder_Blocks'),
             (N'inventory.usp_StockLevel_Search'), (N'inventory.usp_StockLevel_CompanySearch'),
             (N'inventory.usp_ItemWarehouseLevel_Set'), (N'inventory.usp_ItemWarehouseLevel_Remove'),
             (N'inventory.usp_ItemWarehouseLevel_History'), (N'inventory.usp_ItemWarehouseLevel_ImportCheck'),
             (N'inventory.usp_ItemWarehouseLevel_Import'),
             (N'inventory.usp_TransferOrder_Get'), (N'inventory.usp_TransferOrder_Availability'),
             (N'inventory.usp_TransferOrder_FillToMax'), (N'inventory.usp_TransferOrder_BelowMinCandidates'),
             (N'inventory.usp_TransferOrder_CreateFromLevels'),
             (N'masterdata.usp_Warehouse_Create'), (N'masterdata.usp_Warehouse_Update'), (N'masterdata.usp_Warehouse_Lookup'),
             (N'inventory.usp_Item_Delete'),
             (N'reporting.usp_Dashboard_StockLevels')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName);

-- 2. Every level at a warehouse at the bottom of the tree, never On the way (expected: 0 rows)
SELECT i.ItemCode, w.WarehouseCode, w.IsTransit
FROM inventory.ItemWarehouseLevels lv
INNER JOIN inventory.Items i       ON i.Id = lv.ItemId
INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId
WHERE w.IsTransit = 1 OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0;

-- 3. The two permissions (expected: 2 rows, with their role counts)
SELECT p.Code, p.Name, p.SortOrder, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p
WHERE p.Code LIKE N'inventory.stocklevels.%'
ORDER BY p.SortOrder;

-- 4. The levels' on hand is the ledger's (expected: 0 rows)
SELECT lv.ItemId, lv.WarehouseId, p.OnHandBase, Ledger = inventory.fn_StockOnHand(lv.ItemId, lv.WarehouseId)
FROM inventory.ItemWarehouseLevels lv
CROSS APPLY inventory.fn_StockPosition(lv.ItemId, lv.WarehouseId, NULL) p
WHERE p.OnHandBase <> inventory.fn_StockOnHand(lv.ItemId, lv.WarehouseId);

-- 5. The two level keys cascade (expected: 2 rows)
SELECT fk.name, ReferencedTable = OBJECT_SCHEMA_NAME(fk.referenced_object_id) + N'.' + OBJECT_NAME(fk.referenced_object_id),
       fk.delete_referential_action_desc
FROM sys.foreign_keys fk
WHERE fk.parent_object_id = OBJECT_ID(N'inventory.ItemWarehouseLevels') AND fk.delete_referential_action = 1;

-- 6. One formula (M6): where a warehouse stands, read set-based (fn_TransferPositions and the ledger, as Stock Levels,
--    the Dashboard and the transfer order page read it), is fn_StockPosition's, pair by pair (script 90's
--    fn_TransferPosition) - on the 200 levels changed last, so the check stays quick at every start (expected: 0 rows)
DROP TABLE IF EXISTS #chk91;
SELECT TOP (200) lv.ItemId, lv.WarehouseId, lv.UpdatedAtUtc
INTO #chk91
FROM inventory.ItemWarehouseLevels lv
ORDER BY lv.UpdatedAtUtc DESC, lv.ItemId, lv.WarehouseId;

SELECT c.ItemId, c.WarehouseId,
       OnePair = CONCAT(p.OnHandBase, N'/', p.InOnTheWayBase, N'/', p.InToDispatchBase, N'/', p.OutToDispatchBase, N'/', p.ProjectedBase, N'/', p.Status, N'/', p.ToReachMaxBase),
       SetBased = CONCAT(q.OnHandBase, N'/', q.InOnTheWayBase, N'/', q.InToDispatchBase, N'/', q.OutToDispatchBase, N'/', st.ProjectedBase, N'/', st.Status, N'/', st.ToReachMaxBase)
FROM #chk91 c
INNER JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = c.ItemId AND lv.WarehouseId = c.WarehouseId
CROSS APPLY inventory.fn_StockPosition(c.ItemId, c.WarehouseId, NULL) p
LEFT JOIN inventory.fn_TransferPositions(NULL) tp ON tp.ItemId = c.ItemId AND tp.WarehouseId = c.WarehouseId
CROSS APPLY (SELECT OnHandBase = inventory.fn_StockOnHand(c.ItemId, c.WarehouseId), InOnTheWayBase = ISNULL(tp.InOnTheWayBase, 0),
                    InToDispatchBase = ISNULL(tp.InToDispatchBase, 0), OutToDispatchBase = ISNULL(tp.OutToDispatchBase, 0)) q
CROSS APPLY inventory.fn_StockLevelState(q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase,
                                         lv.MinQuantityBase, lv.MaxQuantityBase) st
WHERE p.OnHandBase <> q.OnHandBase OR p.InOnTheWayBase <> q.InOnTheWayBase OR p.InToDispatchBase <> q.InToDispatchBase
   OR p.OutToDispatchBase <> q.OutToDispatchBase OR p.ProjectedBase <> st.ProjectedBase OR p.Status <> st.Status
   OR p.ToReachMaxBase <> st.ToReachMaxBase;

DROP TABLE #chk91;

PRINT 'Script 91 applied: stock levels per warehouse and Fill to Max.';
GO
