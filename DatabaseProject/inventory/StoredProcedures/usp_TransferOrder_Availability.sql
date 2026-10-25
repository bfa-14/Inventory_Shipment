/* 13.3 WHAT FROM HOLDS AND TO EXPECTS, per item, for a draft's lines (re-asked by the page when an item, From or To
   changes): the five figures of the Get's lines, from the same fn_TransferPosition (one formula, M6). Information
   only: Release reserves nothing (FB rule 16), the dispatch checks the real stock. @ExcludeOrderId = the draft being
   edited, so its own lines are never counted against it. Asked for the pair a draft can hold only (62000 otherwise, in
   Save's words): two different warehouses that exist, neither an On the way warehouse - an inactive one is answered (a
   draft may still hold it). */
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
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0)
    FROM @ItemIds x
    OUTER APPLY inventory.fn_TransferPosition(x.Id, @FromWarehouseId, @ExcludeOrderId) pf
    OUTER APPLY inventory.fn_TransferPosition(x.Id, @ToWarehouseId, @ExcludeOrderId) pt
    ORDER BY x.Id;
END

GO

