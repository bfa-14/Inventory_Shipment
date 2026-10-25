/* 13.2 ONE TRANSFER ORDER, 6 result sets (none with rows when the id is unknown; the API answers 404):
     1 header: every column; the order's branch, From and To with their branches; the TRO type's NeedsApproval and
       NumberOnPost; the names behind every stamp; ReturnOfNumber; the figures, shown status and Late of
       fn_TransferOrder_State; OnTheWayValueBase (the pieces on the way at the cost frozen at their dispatch); per
       action Can{Action} and {Action}BlockedReason (the first row of fn_TransferOrder_Blocks: the reason the action
       would be refused with, NULL = allowed), and CanEditExpectedArrival / EditExpectedArrivalBlockedReason (rule T9:
       only the notes change on a received, closed or cancelled order)
     2 lines: item, unit, Ordered (in the unit and in pcs), the counters, To dispatch, On the way, and where From and To
       stand with transfers (fn_TransferPosition, this order left out): on hand at From, what the other released
       orders still take from it, available (never below 0); on hand at To, what released orders still bring to it
     3 dispatches and receipts in the order they were posted, each with its own Reverse and Change ETA answers
     4 their lines (a receipt line names the dispatch it receives)
     5 audit, newest first
     6 the returns of this order
   @UserId: the reader, for the approval right of Release / Approve / Reject (Blocks). */
CREATE   PROCEDURE inventory.usp_TransferOrder_Get
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
                        UpdateDetailsR      = MAX(CASE WHEN a.Action = N'UpdateDetails'      THEN a.Message END)
                 FROM @B a) k
    -- (T9) Expected arrival and Reference No. stay editable on a released order until it is received or closed
    CROSS APPLY (SELECT Reason = CASE WHEN o.Status = 3 OR st.DisplayStatus IN (N'Received', N'Closed')
                                      THEN N'Only the notes can change on a received, closed or cancelled transfer order.'
                                      ELSE k.UpdateDetailsR END) ea
    WHERE o.Id = @Id;

    -- 2: lines, and where From and To stand with transfers (this order left out)
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
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    INNER JOIN inventory.Items i          ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu     ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut    ON ut.Id = iu.UnitTypeId
    OUTER APPLY inventory.fn_TransferPosition(l.ItemId, o.FromWarehouseId, @Id) pf
    OUTER APPLY inventory.fn_TransferPosition(l.ItemId, o.ToWarehouseId, @Id) pt
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

