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
CREATE   FUNCTION inventory.fn_TransferFill_Plan
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

