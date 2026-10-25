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
CREATE   FUNCTION inventory.fn_TransferOrder_Blocks (@Id INT, @UserId INT)
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

