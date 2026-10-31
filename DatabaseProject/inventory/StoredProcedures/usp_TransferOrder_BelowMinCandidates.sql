/* (91) THE "ADD ITEMS BELOW MIN" DRAWER: every level at the order's To for an ACTIVE item (+ the filters), each item in
   each of its units, planned by inventory.fn_TransferFill_Plan (positions once per item; OtherLinesBase = what the
   order already holds of the item). Result 1, per item: where To stands, Min / Max, Need, what From has available;
   IsBelowMin counts the order's own lines for an item on it (an item the order covers is not "below Min"); with
   @OnlyBelowMin only those. Result 2, per item and unit: the proposal (Filled, else why not). The same refusals as
   Add items below Min (fn_TransferOrder_Blocks, AddBelowMin). */
CREATE   PROCEDURE inventory.usp_TransferOrder_BelowMinCandidates
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

