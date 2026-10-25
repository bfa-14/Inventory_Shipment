/* (91) WHAT FROM HOLDS AND TO EXPECTS, per item, for a draft's lines: script 90's five figures and refusals (From = To;
   a warehouse missing or On the way: 62000), + To's level and Projected before the draft, From's Projected and Min
   (the names of Get's lines), so the grid shows Min / Max / Projected at {To} on an unsaved draft (3.3.6.2). */
-- Re-created (91) from the body of script 90: + ToInOnTheWayBase, ToInToDispatchBase, ToOutToDispatchBase,
-- ToProjectedBeforeBase, ToHasLevel, ToMinBase, ToMaxBase, FromProjectedBeforeBase, FromHasLevel, FromMinBase.
CREATE   PROCEDURE inventory.usp_TransferOrder_Availability
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

