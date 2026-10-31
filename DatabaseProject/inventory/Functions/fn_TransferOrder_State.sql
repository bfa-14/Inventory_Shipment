--      reversed postings only), the status it is SHOWN with, and Late. Shown for a released order, the first that
--      applies: Released (nothing dispatched or closed yet), Partly dispatched (something still to dispatch, not
--      closed), Dispatched (goods on the way, nothing arrived yet), Partly received (goods on the way, some arrived or
--      written off), Closed ("Nothing more will be sent", everything sent has arrived), Received. LATE (UTC today, the
--      movements' rule): a released order still to dispatch after its Expected arrival and not closed, or a posted
--      dispatch with pieces on the way after its ETA. No row for an order that does not exist.
CREATE   FUNCTION inventory.fn_TransferOrder_State (@Id INT)
RETURNS TABLE
AS
RETURN
SELECT t.OrderedBase, t.DispatchedBase, t.ReceivedBase, t.LostBase, t.NotSentBase, t.ToDispatchBase,
       OnTheWayBase   = t.DispatchedBase - t.ReceivedBase - t.LostBase,
       t.ItemCount,
       LateDispatches = ld.N,
       IsLate         = CAST(CASE WHEN o.Status = 2
                                   AND ((t.ToDispatchBase > 0 AND o.NotSentAtUtc IS NULL AND o.ExpectedArrival < d.Today) OR ld.N > 0)
                                  THEN 1 ELSE 0 END AS BIT),
       DisplayStatus  = CAST(CASE o.Status WHEN 1 THEN N'Draft' WHEN 4 THEN N'PendingApproval' WHEN 3 THEN N'Cancelled' ELSE
                                 CASE WHEN t.DispatchedBase = 0 AND t.NotSentBase = 0                         THEN N'Released'
                                      WHEN t.ToDispatchBase > 0 AND o.NotSentAtUtc IS NULL                    THEN N'PartlyDispatched'
                                      WHEN t.DispatchedBase - t.ReceivedBase - t.LostBase > 0
                                           AND t.ReceivedBase = 0 AND t.LostBase = 0                          THEN N'Dispatched'
                                      WHEN t.DispatchedBase - t.ReceivedBase - t.LostBase > 0                 THEN N'PartlyReceived'
                                      WHEN t.NotSentBase > 0                                                  THEN N'Closed'
                                      ELSE N'Received' END END AS NVARCHAR(20))
FROM inventory.TransferOrders o
CROSS JOIN (SELECT Today = CAST(SYSUTCDATETIME() AS DATE)) d
CROSS APPLY (SELECT OrderedBase    = ISNULL(SUM(l.OrderedBase), 0),
                    DispatchedBase = ISNULL(SUM(l.DispatchedBase), 0),
                    ReceivedBase   = ISNULL(SUM(l.ReceivedBase), 0),
                    LostBase       = ISNULL(SUM(l.LostBase), 0),
                    NotSentBase    = ISNULL(SUM(l.NotSentBase), 0),
                    ToDispatchBase = ISNULL(SUM(CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                                     THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END), 0),
                    ItemCount      = COUNT(DISTINCT l.ItemId)
             FROM inventory.TransferOrderLines l
             WHERE l.TransferOrderId = o.Id) t
CROSS APPLY (SELECT N = COUNT(*)
             FROM inventory.TransferPostings p
             WHERE p.TransferOrderId = o.Id AND p.Kind = N'Dispatch' AND p.Status = 2 AND p.Eta < d.Today
               AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id AND pl.QuantityBase > pl.SettledBase)) ld
WHERE o.Id = @Id;

GO

