/* (91) WHAT RELEASED TRANSFER ORDERS STILL BRING TO AND TAKE FROM EVERY WAREHOUSE, per item: script 90's
   fn_TransferPosition's three sums (the same CASE) for every item and warehouse at once. For the readers of MANY pairs -
   Stock Levels, the Dashboard, Fill to Max, its drawer and Create transfer order - which called fn_TransferPosition
   once per pair and so read the item's whole transfer history once per pair (4 to 7 s for 6,000 levels on 20,000
   released orders). A transfer order's own page and a draft's availability call read a few dozen pairs: there
   fn_StockPosition, once per pair, stays the cheaper. Only the OPEN lines are summed: a line still to dispatch or on
   the way (a line received, written off or no longer sent adds 0 to every sum, so the figures are the same).
   @ExcludeOrderId leaves one order out, as fn_TransferPosition. Grouped by the line's ItemId, so a reader's filter on
   the item reaches the lines. Check 6 compares it with fn_TransferPosition. */
CREATE   FUNCTION inventory.fn_TransferPositions (@ExcludeOrderId INT)
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

