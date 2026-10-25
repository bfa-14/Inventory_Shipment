using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory.Transfers;

/// <summary>
/// Transfer orders (script 90): stock moved from one leaf warehouse (From) to another (To), of any branch, without
/// changing its cost.
///
/// THREE DOCUMENTS, ONE PAGE. The ORDER (TRO) says what should move; a DISPATCH (TRD, numbered by the source branch)
/// takes pieces out of From onto the hidden "On the way" warehouse of the destination branch; a TRANSFER RECEIPT (TRR,
/// numbered by the destination branch) takes them from there into To, each receipt line pointing at the dispatch line
/// it receives. Dispatches and receipts are the order's "postings": no page and no draft of their own.
///
/// STORED AND SHOWN STATUSES. The order stores Draft, Waiting for approval, Released or Cancelled; a released order
/// SHOWS how far its postings went (Released, Partly dispatched, Dispatched, Partly received, Closed, Received), worked
/// out by inventory.fn_TransferOrder_State from the counters (the script-77 pattern).
/// </summary>
public static class TransferOrderStatuses
{
    public const byte DraftCode = 1;
    public const byte ReleasedCode = 2;
    public const byte CancelledCode = 3;
    public const byte PendingApprovalCode = 4;

    public const string Draft = "Draft";
    public const string PendingApproval = "PendingApproval";
    public const string Released = "Released";
    public const string Cancelled = "Cancelled";

    /// <summary>The stored status by its code (TransferOrders.Status 1 / 2 / 3 / 4).</summary>
    public static string From(byte code) => code switch
    {
        ReleasedCode => Released,
        CancelledCode => Cancelled,
        PendingApprovalCode => PendingApproval,
        _ => Draft,
    };
}

/// <summary>The two kinds of posting of an order, as TransferPostings.Kind holds them.</summary>
public static class TransferPostingKinds
{
    public const string Dispatch = "Dispatch";
    public const string Receipt = "Receipt";
}

/// <summary>
/// Why pieces dispatched will not arrive ("Nothing more will arrive"): they are written off from On the way at the
/// average (TRF_LOSS). OTHER needs a note; the database refuses any other code.
/// </summary>
public static class TransferLossReasons
{
    public const string Damaged = "DAMAGED";
    public const string Missing = "MISSING";
    public const string DispatchCount = "DISPATCHCOUNT";
    public const string Other = "OTHER";

    /// <summary>Upper-case and trimmed; blank is null (the procedure then names the line that needs a reason).</summary>
    public static string? Normalize(string? code)
        => string.IsNullOrWhiteSpace(code) ? null : code.Trim().ToUpperInvariant();

    public static string Name(string? code) => Normalize(code) switch
    {
        Damaged => "Damaged",
        Missing => "Missing / stolen",
        DispatchCount => "Wrongly counted at dispatch",
        Other => "Other",
        null => string.Empty,
        var unknown => unknown,
    };
}

/* ── the list ─────────────────────────────────────────────────────────────────────────────────── */

/// <summary>A warehouse as a transfer names it: "LKS-01 - Likasi Warehouse", its branch dimmed below.</summary>
public sealed class TransferWarehouseRefDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public int? BranchId { get; init; }
    public string? BranchCode { get; init; }
    public string? BranchName { get; init; }
}

/// <summary>One row of the Transfer Orders list (inventory.usp_TransferOrder_Search, result 1).</summary>
public sealed class TransferOrderListItemDto
{
    public int Id { get; init; }

    /// <summary>Null only on a draft whose type numbers at release ("Assigned on release").</summary>
    public string? DocumentNumber { get; init; }

    public DateOnly DocumentDate { get; init; }

    /// <summary>The numbering branch: From's.</summary>
    public int BranchId { get; init; }

    public string? BranchCode { get; init; }
    public TransferWarehouseRefDto From { get; init; } = new();
    public TransferWarehouseRefDto To { get; init; } = new();

    /// <summary>Stored: Draft | PendingApproval | Released | Cancelled (<see cref="TransferOrderStatuses"/>).</summary>
    public string Status { get; init; } = TransferOrderStatuses.Draft;

    /// <summary>Shown: Draft | PendingApproval | Released | PartlyDispatched | Dispatched | PartlyReceived | Received | Closed | Cancelled.</summary>
    public string DisplayStatus { get; init; } = TransferOrderStatuses.Draft;

    /// <summary>Something to dispatch after the Expected arrival, or a dispatch with pieces on the way after its ETA (UTC today).</summary>
    public bool IsLate { get; init; }

    public int ItemCount { get; init; }
    public int OrderedBase { get; init; }
    public int DispatchedBase { get; init; }
    public int ReceivedBase { get; init; }
    public int OnTheWayBase { get; init; }
    public int ToDispatchBase { get; init; }
    public int NotSentBase { get; init; }

    /// <summary>Written off as lost on the way: the list's orange "{n} lost" badge.</summary>
    public int LostBase { get; init; }

    public DateOnly? ExpectedArrival { get; init; }
    public string? ReferenceNo { get; init; }

    /// <summary>A return: the order whose goods it sends back ("Return of TRO-…").</summary>
    public int? ReturnOfOrderId { get; init; }

    public string? ReturnOfNumber { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

/// <summary>The list's summary row, over EVERY order of the filter, not only the page (result 2).</summary>
public sealed class TransferOrderListTotalsDto
{
    public int Orders { get; init; }
    public int OnTheWayBase { get; init; }
    public int LateOrders { get; init; }
    public int WaitingForApproval { get; init; }
}

public sealed class TransferOrderListResult
{
    public IReadOnlyList<TransferOrderListItemDto> Items { get; init; } = [];
    public int TotalCount { get; init; }
    public int Page { get; init; }
    public int PageSize { get; init; }
    public TransferOrderListTotalsDto Totals { get; init; } = new();
}

/// <summary>The list's filters (GET api/inventory/transfers). Every one is optional.</summary>
public sealed class TransferOrderQuery
{
    /// <summary>The number, the reference, From's or To's code or name, an item code on a line, the number of a dispatch or receipt.</summary>
    public string? Search { get; init; }

    /// <summary>A shown status (Draft, PendingApproval, Released, PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled) or Open.</summary>
    public string? Status { get; init; }

    /// <summary>From's OR To's branch: a transfer concerns both.</summary>
    public int? BranchId { get; init; }

    public int? FromWarehouseId { get; init; }
    public int? ToWarehouseId { get; init; }
    public bool OnTheWayOnly { get; init; }
    public bool LateOnly { get; init; }

    /// <summary>Stored status Waiting for approval: the approvers' list.</summary>
    public bool WaitingForApproval { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public int? ItemId { get; init; }

    /// <summary>DocumentNumber | DocumentDate | FromWarehouse | ToWarehouse | Status | OrderedBase | OnTheWayBase | ExpectedArrival | CreatedAtUtc.</summary>
    public string? SortColumn { get; init; }

    /// <summary>ASC | DESC (the default).</summary>
    public string? SortDirection { get; init; }

    public int Page { get; init; } = 1;

    /// <summary>At most 200.</summary>
    public int PageSize { get; init; } = 25;
}

/// <summary>The approvers' menu count (0 for a reader who may not approve).</summary>
public sealed class TransferWaitingDto
{
    public int WaitingForApproval { get; init; }
}

/* ── where From and To stand ──────────────────────────────────────────────────────────────────── */

/// <summary>
/// One item at From and at To, for the lines of a draft (inventory.fn_TransferPosition: the one formula). Information
/// only: Release reserves nothing, and the dispatch checks the real stock.
/// </summary>
public sealed class TransferAvailabilityDto
{
    public int ItemId { get; init; }
    public int OnHandFromBase { get; init; }

    /// <summary>What the other released orders still take from From.</summary>
    public int CommittedFromBase { get; init; }

    /// <summary>On hand − committed, never below 0: "Available at {From}".</summary>
    public int AvailableFromBase { get; init; }

    public int OnHandToBase { get; init; }

    /// <summary>On the way to To, and still to dispatch to it, on released orders.</summary>
    public int IncomingToBase { get; init; }
}

/// <summary>GET availability?fromWarehouseId=&amp;toWarehouseId=&amp;itemIds=1,2,3&amp;excludeOrderId=.</summary>
public sealed class TransferAvailabilityQuery
{
    public int? FromWarehouseId { get; init; }
    public int? ToWarehouseId { get; init; }

    /// <summary>Item ids separated by commas.</summary>
    public string? ItemIds { get; init; }

    /// <summary>The order being edited: its own lines are not "promised to other orders".</summary>
    public int? ExcludeOrderId { get; init; }
}

/* ── the order ────────────────────────────────────────────────────────────────────────────────── */

/// <summary>The order's figures in pcs (inventory.fn_TransferOrder_State).</summary>
public sealed class TransferOrderFiguresDto
{
    public int OrderedBase { get; init; }
    public int DispatchedBase { get; init; }
    public int ReceivedBase { get; init; }
    public int OnTheWayBase { get; init; }
    public int ToDispatchBase { get; init; }
    public int NotSentBase { get; init; }
    public int LostBase { get; init; }
    public int ItemCount { get; init; }

    /// <summary>Posted dispatches with pieces on the way after their ETA.</summary>
    public int LateDispatches { get; init; }
}

/// <summary>Who asked for the approval and who decided. All empty on an order released without approval.</summary>
public sealed class TransferApprovalDto
{
    public DateTime? RequestedAtUtc { get; init; }
    public string? RequestedByName { get; init; }
    public DateTime? ApprovedAtUtc { get; init; }
    public string? ApprovedByName { get; init; }

    /// <summary>Approve &amp; release of a draft ("Approved directly").</summary>
    public bool ApprovedDirectly { get; init; }

    /// <summary>Shown on the draft until it is sent again: "Rejected by {name} on {date}: {reason}".</summary>
    public DateTime? RejectedAtUtc { get; init; }

    public string? RejectedByName { get; init; }
    public string? RejectReason { get; init; }
}

/// <summary>Who did something and when; the reason where the action asks for one.</summary>
public sealed class TransferStampDto
{
    public DateTime AtUtc { get; init; }
    public string? ByName { get; init; }
    public string? Reason { get; init; }
}

/// <summary>The order a return sends back, or one of the returns of this order.</summary>
public sealed class TransferOrderLinkDto
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }
    public DateOnly? DocumentDate { get; init; }
    public string? Status { get; init; }
    public string? DisplayStatus { get; init; }
}

/// <summary>One action of the order as the database judges it now: allowed, or the sentence it would be refused with.</summary>
public sealed class TransferAbilityDto
{
    public bool Allowed { get; init; }
    public string? Reason { get; init; }

    /// <summary>The database's Can{Action} and {Action}BlockedReason: a refused action always carries its sentence.</summary>
    public static TransferAbilityDto Of(bool allowed, string? reason)
        => allowed && string.IsNullOrEmpty(reason)
            ? new TransferAbilityDto { Allowed = true }
            : new TransferAbilityDto { Allowed = false, Reason = reason };
}

/// <summary>
/// EVERY RULE IS THE DATABASE'S: each action's first row of inventory.fn_TransferOrder_Blocks, the sentence the action
/// would be refused with, so a disabled button and the refusal of its click can never differ (the script-83 pattern).
/// Permissions are not in it: the page hides what the reader may not use (the approval right excepted, the decision's own
/// rule). <see cref="EditExpectedArrival"/> is the header's field: only the notes change on a received, closed or
/// cancelled order.
/// </summary>
public sealed class TransferOrderAbilitiesDto
{
    public TransferAbilityDto Edit { get; init; } = new();
    public TransferAbilityDto Delete { get; init; } = new();
    public TransferAbilityDto Release { get; init; } = new();
    public TransferAbilityDto SendForApproval { get; init; } = new();
    public TransferAbilityDto Approve { get; init; } = new();
    public TransferAbilityDto Reject { get; init; } = new();
    public TransferAbilityDto Withdraw { get; init; } = new();
    public TransferAbilityDto BackToDraft { get; init; } = new();
    public TransferAbilityDto Dispatch { get; init; } = new();
    public TransferAbilityDto Receive { get; init; } = new();
    public TransferAbilityDto DispatchAndReceive { get; init; } = new();
    public TransferAbilityDto NothingMoreSent { get; init; } = new();
    public TransferAbilityDto Cancel { get; init; } = new();
    public TransferAbilityDto CreateReturn { get; init; } = new();
    public TransferAbilityDto UpdateDetails { get; init; } = new();
    public TransferAbilityDto EditExpectedArrival { get; init; } = new();
}

/// <summary>One line of the order, with where From and To stand for its item (this order left out).</summary>
public sealed class TransferOrderLineDto
{
    public int Id { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public bool ItemIsActive { get; init; }
    public int ItemUnitId { get; init; }
    public string UnitName { get; init; } = string.Empty;
    public bool IsBaseUnit { get; init; }

    /// <summary>Ordered, in the line's unit ("2 BOX"); <see cref="OrderedBase"/> is the same in pcs.</summary>
    public int Quantity { get; init; }

    /// <summary>The unit's packing formula when the line was saved.</summary>
    public int PackingFormula { get; init; }

    public int OrderedBase { get; init; }
    public int DispatchedBase { get; init; }
    public int ReceivedBase { get; init; }
    public int LostBase { get; init; }
    public int NotSentBase { get; init; }

    /// <summary>Ordered − Dispatched − Not sent, never below 0.</summary>
    public int ToDispatchBase { get; init; }

    /// <summary>Dispatched − Received − Lost.</summary>
    public int OnTheWayBase { get; init; }

    public string? Notes { get; init; }
    public int OnHandFromBase { get; init; }
    public int CommittedFromBase { get; init; }
    public int AvailableFromBase { get; init; }
    public int OnHandToBase { get; init; }
    public int IncomingToBase { get; init; }
}

/// <summary>The On the way warehouse a dispatch put its goods in: "OTW-BR-002 - On the way to BR-002 (transfers)".</summary>
public sealed class TransferTransitWarehouseDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
}

/// <summary>A reversal: "Reversed on {date} by {name}: {reason}".</summary>
public sealed class TransferReversalDto
{
    /// <summary>The date the reversal counts on.</summary>
    public DateOnly Date { get; init; }

    public DateTime AtUtc { get; init; }
    public string? ByName { get; init; }
    public string Reason { get; init; } = string.Empty;
}

/// <summary>One line of a dispatch or receipt.</summary>
public sealed record TransferPostingLineDto
{
    public int Id { get; init; }

    /// <summary>A dispatch line takes its order line's number; a receipt numbers its lines 1..n.</summary>
    public int LineNumber { get; init; }

    public int TransferOrderLineId { get; init; }
    public int OrderLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>Dispatch: pieces sent; receipt: pieces received (0 on a line that only writes off).</summary>
    public int QuantityBase { get; init; }

    /// <summary>Receipt lines: written off as lost.</summary>
    public int LostBase { get; init; }

    public string? LossReasonCode { get; init; }
    public string? LossNote { get; init; }

    /// <summary>Dispatch lines: received + lost by posted receipts.</summary>
    public int SettledBase { get; init; }

    /// <summary>Dispatch lines: quantity − settled while the dispatch is posted, 0 once it is reversed.</summary>
    public int OnTheWayBase { get; init; }

    /// <summary>Receipt lines: the dispatch line received, and its dispatch's number.</summary>
    public int? DispatchLineId { get; init; }

    public string? DispatchNumber { get; init; }

    /// <summary>The average frozen at dispatch (information: a transfer moves no cost). Null without the value permission.</summary>
    public decimal? UnitCostBase { get; init; }

    /// <summary>The average a loss was written off at. Null without the value permission, or without a loss.</summary>
    public decimal? LossUnitCostBase { get; init; }
}

/// <summary>A dispatch (TRD) or a transfer receipt (TRR) of the order, with its own Reverse and Change ETA answers.</summary>
public sealed record TransferPostingDto
{
    public int Id { get; init; }

    /// <summary>Dispatch | Receipt.</summary>
    public string Kind { get; init; } = TransferPostingKinds.Dispatch;

    /// <summary>TRD or TRR.</summary>
    public string DocumentTypeCode { get; init; } = string.Empty;

    public string DocumentNumber { get; init; } = string.Empty;
    public DateOnly PostingDate { get; init; }

    /// <summary>Dispatches only (required there); null on a receipt.</summary>
    public DateOnly? Eta { get; init; }

    /// <summary>Waybill / truck (dispatch), delivery note (receipt).</summary>
    public string? ReferenceNo { get; init; }

    public string? Notes { get; init; }

    /// <summary>Posted | Reversed.</summary>
    public string Status { get; init; } = "Posted";

    /// <summary>Dispatches: the On the way warehouse of the destination branch.</summary>
    public TransferTransitWarehouseDto? TransitWarehouse { get; init; }

    /// <summary>The numbering branch: From's for a dispatch, To's for a receipt.</summary>
    public string? BranchCode { get; init; }

    /// <summary>"Dispatch and receive": the receipt points at its dispatch ("Posted together with {number}").</summary>
    public int? PostedWithId { get; init; }

    public string? PostedWithNumber { get; init; }
    public int TotalQuantityBase { get; init; }
    public int TotalLostBase { get; init; }

    /// <summary>Dispatches: pieces still on the way.</summary>
    public int OnTheWayBase { get; init; }

    /// <summary>A posted dispatch with pieces on the way after its ETA (UTC today).</summary>
    public bool IsLate { get; init; }

    /// <summary>Dispatch: Σ sent × frozen cost; receipt: Σ received × the dispatch's cost. Null without the value permission.</summary>
    public decimal? ValueBase { get; init; }

    /// <summary>Σ lost × the average at receipt. Null without the value permission.</summary>
    public decimal? LostValueBase { get; init; }

    public DateTime PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }

    /// <summary>Null while posted.</summary>
    public TransferReversalDto? Reversed { get; init; }

    public bool CanReverse { get; init; }
    public string? ReverseBlockedReason { get; init; }
    public bool CanChangeEta { get; init; }
    public string? ChangeEtaBlockedReason { get; init; }
    public IReadOnlyList<TransferPostingLineDto> Lines { get; init; } = [];
}

/// <summary>One entry of the order's history, newest first.</summary>
public sealed class TransferOrderAuditDto
{
    public long Id { get; init; }

    /// <summary>The dispatch or receipt the entry is about, if any.</summary>
    public int? PostingId { get; init; }

    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>A transfer order with its lines, postings, history and the answer of every action (GET /{id}; every action answers it again).</summary>
public sealed record TransferOrderDto
{
    public int Id { get; init; }

    /// <summary>Null while not numbered yet: "Assigned on the first save", or "Assigned on release" when <see cref="NumberOnPost"/>.</summary>
    public string? DocumentNumber { get; init; }

    public DateOnly DocumentDate { get; init; }

    /// <summary>From's branch (kept up to date while a draft); it numbers the order.</summary>
    public int BranchId { get; init; }

    public string? BranchCode { get; init; }
    public TransferWarehouseRefDto From { get; init; } = new();
    public TransferWarehouseRefDto To { get; init; } = new();
    public DateOnly? ExpectedArrival { get; init; }
    public string? ReferenceNo { get; init; }
    public string? Notes { get; init; }

    /// <summary>Stored: Draft | PendingApproval | Released | Cancelled.</summary>
    public string Status { get; init; } = TransferOrderStatuses.Draft;

    /// <summary>Shown (for a released order, how far its postings went).</summary>
    public string DisplayStatus { get; init; } = TransferOrderStatuses.Draft;

    public bool IsLate { get; init; }

    /// <summary>The TRO type's "Needs approval before release" (Configuration › Document Types).</summary>
    public bool NeedsApproval { get; init; }

    /// <summary>The TRO type numbers at release instead of the first save.</summary>
    public bool NumberOnPost { get; init; }

    public TransferOrderFiguresDto Totals { get; init; } = new();

    /// <summary>Σ on the way × the cost frozen at dispatch. Null without the value permission.</summary>
    public decimal? OnTheWayValueBase { get; init; }

    public TransferApprovalDto Approval { get; init; } = new();
    public TransferStampDto? Released { get; init; }

    /// <summary>"Nothing more will be sent" (the Closed stamp), with its reason.</summary>
    public TransferStampDto? NotSent { get; init; }

    public TransferStampDto? Cancelled { get; init; }

    /// <summary>A return: the order it sends back.</summary>
    public TransferOrderLinkDto? ReturnOf { get; init; }

    /// <summary>The returns of this order.</summary>
    public IReadOnlyList<TransferOrderLinkDto> Returns { get; init; } = [];

    public TransferOrderAbilitiesDto Abilities { get; init; } = new();
    public IReadOnlyList<TransferOrderLineDto> Lines { get; init; } = [];

    /// <summary>Dispatches and receipts in the order they were posted.</summary>
    public IReadOnlyList<TransferPostingDto> Postings { get; init; } = [];

    /// <summary>Newest first.</summary>
    public IReadOnlyList<TransferOrderAuditDto> Audit { get; init; } = [];

    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }

    /// <summary>Base64 ROWVERSION of the ORDER: every action, the postings' included, sends it back.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/* ── requests ─────────────────────────────────────────────────────────────────────────────────── */

/// <summary>
/// One line of a draft. Nothing here is checked but the lengths: the procedure says "Line {n}: item not found." and
/// the like in its own words, the line numbered as the page shows it.
/// </summary>
public sealed class TransferOrderLineRequest
{
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public int ItemUnitId { get; init; }

    /// <summary>Ordered in the unit: a whole number above 0.</summary>
    public int Quantity { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>
/// Creates or replaces a DRAFT, lines and all (POST / and PUT /{id}). The lines may be empty on a draft. A missing date
/// or warehouse is the procedure's to refuse ("Order date is required.", "Choose the warehouse the goods leave from.").
/// </summary>
public sealed class SaveTransferOrderRequest
{
    public DateOnly? DocumentDate { get; init; }
    public int? FromWarehouseId { get; init; }
    public int? ToWarehouseId { get; init; }
    public DateOnly? ExpectedArrival { get; init; }

    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>Base64 ROWVERSION read with the order; null on a new one (and skips the check).</summary>
    public string? RowVersion { get; init; }

    public IReadOnlyList<TransferOrderLineRequest> Lines { get; init; } = [];
}

/// <summary>"Save details" once the order is no longer a draft (rule T9): on a received, closed or cancelled one, the notes only.</summary>
public sealed class UpdateTransferDetailsRequest
{
    public DateOnly? ExpectedArrival { get; init; }

    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public string? RowVersion { get; init; }
}

/// <summary>Release, Send for approval, Approve, Withdraw: the order's row version.</summary>
public sealed class TransferRowVersionRequest
{
    public string? RowVersion { get; init; }
}

/// <summary>Reject, Back to draft, Nothing more will be sent, Cancel order: the row version and the reason (required by the procedure).</summary>
public sealed class TransferReasonRequest
{
    public string? RowVersion { get; init; }

    [StringLength(300)]
    public string? Reason { get; init; }
}

public sealed class DispatchTransferLineRequest
{
    public int TransferOrderLineId { get; init; }

    /// <summary>Pieces leaving From; lines at 0 are ignored by the procedure.</summary>
    public int QuantityBase { get; init; }
}

/// <summary>A dispatch, or "Dispatch and receive" (its <see cref="Eta"/> is then ignored: the goods arrive the same date).</summary>
public sealed class DispatchTransferRequest
{
    public string? RowVersion { get; init; }
    public DateOnly? Date { get; init; }
    public DateOnly? Eta { get; init; }

    /// <summary>"Waybill / truck".</summary>
    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<DispatchTransferLineRequest> Lines { get; init; } = [];
}

public sealed class ReceiveTransferLineRequest
{
    public int DispatchLineId { get; init; }
    public int ReceivedBase { get; init; }

    /// <summary>The rest of the line's pieces on the way is written off as lost (a reason; a note for Other).</summary>
    public bool NothingMoreWillArrive { get; init; }

    /// <summary>DAMAGED | MISSING | DISPATCHCOUNT | OTHER (<see cref="TransferLossReasons"/>).</summary>
    [StringLength(20)]
    public string? LossReasonCode { get; init; }

    [StringLength(300)]
    public string? LossNote { get; init; }
}

public sealed class ReceiveTransferRequest
{
    public string? RowVersion { get; init; }
    public DateOnly? Date { get; init; }

    /// <summary>"Delivery note no."</summary>
    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<ReceiveTransferLineRequest> Lines { get; init; } = [];
}

/// <summary>Reverse one whole dispatch or receipt: the ORDER's row version, a reason, a date (null = today).</summary>
public sealed class ReverseTransferPostingRequest
{
    public string? RowVersion { get; init; }

    [StringLength(300)]
    public string? Reason { get; init; }

    public DateOnly? Date { get; init; }
}

/// <summary>Change ETA… of a dispatch with goods on the way: the ORDER's row version and the new ETA.</summary>
public sealed class ChangeTransferEtaRequest
{
    public string? RowVersion { get; init; }
    public DateOnly? Eta { get; init; }
}

/* ── answers ──────────────────────────────────────────────────────────────────────────────────── */

/// <summary>Release, the approval cycle, back to draft, nothing more, cancel, reverse, ETA: the order again and what to say.</summary>
public sealed class TransferActionResult
{
    public TransferOrderDto Order { get; init; } = new();

    /// <summary>"TRO-BR-003-000012 released." - shown as it comes.</summary>
    public string Message { get; init; } = string.Empty;

    /// <summary>Release / Approve: the released orders from From that need more than it holds, one sentence per item.</summary>
    public IReadOnlyList<string> Warnings { get; init; } = [];

    /// <summary>An email that could not be queued (the action itself went through): shown orange.</summary>
    public string? EmailWarning { get; init; }
}

/// <summary>A dispatch or receipt just posted.</summary>
public sealed class TransferPostedRefDto
{
    public int Id { get; init; }
    public string Kind { get; init; } = TransferPostingKinds.Dispatch;
    public string DocumentNumber { get; init; } = string.Empty;
}

/// <summary>Dispatch, receive, dispatch and receive: the order again and the postings made (a dispatch, then its receipt).</summary>
public sealed class TransferPostedResult
{
    public TransferOrderDto Order { get; init; } = new();
    public IReadOnlyList<TransferPostedRefDto> Postings { get; init; } = [];

    /// <summary>"TRD-BR-003-000004 posted: 40 pcs left LKS-01."</summary>
    public string Message { get; init; } = string.Empty;
}

/* ── who is told (the approval emails) ────────────────────────────────────────────────────────── */

/// <summary>An approver to tell (inventory.usp_TransferOrder_Approvers, M10): outside the system role, else the system role.</summary>
public sealed class TransferApproverDto
{
    public int UserId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string? Email { get; init; }
}

/// <summary>The requester of an approval, told of the decision.</summary>
public sealed class TransferRequesterDto
{
    public int RequestedById { get; init; }
    public string? RequestedByName { get; init; }
    public string? RequestedByEmail { get; init; }
}
