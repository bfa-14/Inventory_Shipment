/* ================================================================== 10. The transfer functions */

-- (90) THE ONE DEFINITION OF WHERE A WAREHOUSE STANDS WITH TRANSFERS (its lines' "Available at {From}" and "Stock at
--      {To}" on the order page, the availability call, Release's warnings, and the stock levels of script 91).
--      OnHandBase equals inventory.fn_StockOnHand(item, warehouse); the ledger's (ItemId, WarehouseId, MovementDate)
--      index, IX_TransferOrderLines_Item and IX_TransferOrders_To / _From serve it.
CREATE   FUNCTION inventory.fn_TransferPosition (@ItemId INT, @WarehouseId INT, @ExcludeOrderId INT)
RETURNS TABLE
AS
RETURN
(
    -- (90) A WAREHOUSE'S POSITION WITH TRANSFERS: on hand, and what RELEASED transfer orders (Status 2) still bring to it
    --      (on the way, still to dispatch) or still take from it (to dispatch). Drafts and orders waiting for approval
    --      promise nothing; a cancelled order has nothing dispatched; a closed order has nothing left to dispatch.
    --      @ExcludeOrderId leaves one order out (the one being looked at).
    SELECT OnHandBase        = ISNULL(oh.Qty, 0),
           InOnTheWayBase    = ISNULL(ti.OnTheWay, 0),
           InToDispatchBase  = ISNULL(ti.ToDispatch, 0),
           OutToDispatchBase = ISNULL(tx.ToDispatch, 0),
           ProjectedBase     = ISNULL(oh.Qty, 0) + ISNULL(ti.OnTheWay, 0) + ISNULL(ti.ToDispatch, 0) - ISNULL(tx.ToDispatch, 0)
    FROM (SELECT Qty = SUM(m.QuantityBase) FROM inventory.StockMovements m
          WHERE m.ItemId = @ItemId AND m.WarehouseId = @WarehouseId) oh
    CROSS JOIN (SELECT OnTheWay   = SUM(l.DispatchedBase - l.ReceivedBase - l.LostBase),
                       ToDispatch = SUM(CASE WHEN o.NotSentAtUtc IS NULL AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                             THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END)
                FROM inventory.TransferOrderLines l
                INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
                WHERE l.ItemId = @ItemId AND o.ToWarehouseId = @WarehouseId AND o.Status = 2
                  AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)) ti
    CROSS JOIN (SELECT ToDispatch = SUM(CASE WHEN o.NotSentAtUtc IS NULL AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                             THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END)
                FROM inventory.TransferOrderLines l
                INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
                WHERE l.ItemId = @ItemId AND o.FromWarehouseId = @WarehouseId AND o.Status = 2
                  AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)) tx
);

GO

