using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.DTOs.Documents;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/* Goods receipts (scripts 64 and 65): FROM THE SWITCH ON, STOCK ENTERS ONLY THROUGH A POSTED GOODS RECEIPT (GRN). A
   supplier invoice makes the amount payable and sets the invoice cost that received goods are valued at or corrected
   to; the receipt is the moment the goods are counted at the gate. One source per receipt: a container (a draft made
   when its Delivery movement is completed, or "Receive goods..." on it), a purchase order, a posted purchase invoice,
   or none ("Without an order", a supplier required). Draft -> Posted -> Cancelled; numbered per branch at posting
   (GRN-BR-002-000001). Its own tables, not purchase.PurchaseDocuments: a receipt has no price, currency or approval. */

/// <summary>Draft → Posted → Cancelled (purchase.GoodsReceipts.Status).</summary>
public static class GoodsReceiptStatus
{
    public const byte Draft = 1;
    public const byte Posted = 2;
    public const byte Cancelled = 3;

    private static readonly string[] Names = ["Draft", "Posted", "Cancelled"];

    public static string Name(byte status)
        => status is >= Draft and <= Cancelled ? Names[status - 1] : "Unknown";

    /// <summary>The code 1–3 or the name; null when neither.</summary>
    public static byte? ToCode(string? status)
    {
        if (string.IsNullOrWhiteSpace(status))
        {
            return null;
        }

        if (byte.TryParse(status, out var code) && code is >= Draft and <= Cancelled)
        {
            return code;
        }

        var index = Array.FindIndex(Names, n => string.Equals(n, status.Trim(), StringComparison.OrdinalIgnoreCase));
        return index >= 0 ? (byte)(index + 1) : null;
    }
}

/// <summary>Where a goods receipt comes from: its one source (purchase.GoodsReceipts.SourceKind).</summary>
public static class GoodsReceiptSourceKinds
{
    public const string Container = "Container";
    public const string Order = "Order";
    public const string Invoice = "Invoice";

    /// <summary>"Without an order": a supplier is required, the lines carry a typed cost.</summary>
    public const string Manual = "Manual";

    public static readonly string[] All = [Container, Order, Invoice, Manual];

    /// <summary>The kind in its canonical spelling, or null when it is not one.</summary>
    public static string? Normalize(string? kind)
        => All.FirstOrDefault(k => string.Equals(k, kind?.Trim(), StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// Why a line received a different quantity than expected (a container line), or why nothing more will come (a line of
/// an order settled short). A code, plus the free note of <c>VarianceReason</c>.
/// </summary>
public static class GoodsReceiptReasonCodes
{
    public const string ShortShipped = "SHORT";
    public const string Damaged = "DAMAGED";
    public const string Missing = "MISSING";
    public const string WronglyCountedAtLoading = "LOADCOUNT";
    public const string Other = "OTHER";

    public static readonly string[] All = [ShortShipped, Damaged, Missing, WronglyCountedAtLoading, Other];

    /// <summary>
    /// The code trimmed and in capitals, null when blank. An unknown code goes on as it is: the procedure refuses it
    /// with the list of codes in its message.
    /// </summary>
    public static string? Normalize(string? code)
        => string.IsNullOrWhiteSpace(code) ? null : code.Trim().ToUpperInvariant();

    public static string? Name(string? code) => Normalize(code) switch
    {
        ShortShipped => "Short-shipped",
        Damaged => "Damaged",
        Missing => "Missing",
        WronglyCountedAtLoading => "Wrongly counted at loading",
        Other => "Other",
        _ => null,
    };
}

/* ── the list ─────────────────────────────────────────────────────────────────────────────────── */

/// <summary>One row of Purchase › Goods Receipts (purchase.usp_GoodsReceipt_Search).</summary>
public sealed class GoodsReceiptListItemDto
{
    public int Id { get; init; }

    /// <summary>Null on a draft: "Assigned on posting".</summary>
    public string? DocumentNumber { get; init; }

    /// <summary>The date the goods were received.</summary>
    public DateTime DocumentDate { get; init; }

    public byte Status { get; init; }
    public string StatusName { get; init; } = string.Empty;

    /// <summary>Container | Order | Invoice | Manual.</summary>
    public string SourceKind { get; init; } = string.Empty;

    /// <summary>Made by the completion of a Delivery movement.</summary>
    public bool IsAuto { get; init; }

    public int BranchId { get; init; }
    public string? BranchCode { get; init; }
    public string? BranchName { get; init; }

    /// <summary>"Receive into"; null on a container draft whose warehouse is still to choose.</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public int? SupplierId { get; init; }
    public string? SupplierCode { get; init; }

    /// <summary>"Several suppliers" for a container of several suppliers' orders.</summary>
    public string? SupplierName { get; init; }

    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public int? PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
    public int? PurchaseInvoiceId { get; init; }
    public string? PurchaseInvoiceNumber { get; init; }
    public int? MovementId { get; init; }
    public string? MovementNo { get; init; }

    /// <summary>The supplier's delivery note no.</summary>
    public string? SupplierReference { get; init; }

    public int LineCount { get; init; }
    public int ExpectedBase { get; init; }
    public int ReceivedBase { get; init; }

    /// <summary>Pieces settled short (an estimate on a draft: what posting it would settle).</summary>
    public int ShortBase { get; init; }

    /// <summary>Received pieces matched to posted supplier invoices.</summary>
    public int InvoicedBase { get; init; }

    /// <summary>Current value of the lines in base currency; an estimate on a draft (<see cref="IsValueEstimate"/>).</summary>
    public decimal ValueBase { get; init; }

    public bool IsValueEstimate { get; init; }
    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>
/// The totals row of the list, over every receipt of the filter (all pages): what is received and not invoiced yet,
/// in pieces and at the order price - the month-end figure.
/// </summary>
public sealed class GoodsReceiptListTotalsDto
{
    public int ReceivedNotInvoicedBase { get; init; }
    public decimal ReceivedNotInvoicedValueBase { get; init; }
    public int ReceiptCount { get; init; }
    public int DraftCount { get; init; }
}

/// <summary>One page of goods receipts and the totals of the whole filter.</summary>
public sealed class GoodsReceiptListResult
{
    public IReadOnlyList<GoodsReceiptListItemDto> Items { get; init; } = [];

    /// <summary>1-based page number.</summary>
    public int Page { get; init; }

    public int PageSize { get; init; }

    /// <summary>Receipts matching the filters, across every page.</summary>
    public int TotalCount { get; init; }

    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling(TotalCount / (double)PageSize);
    public bool HasNext => Page < TotalPages;
    public bool HasPrevious => Page > 1;
    public GoodsReceiptListTotalsDto Totals { get; init; } = new();
}

/// <summary>The filters of the list (GET api/purchase/goods-receipts).</summary>
public sealed class GoodsReceiptQuery
{
    /// <summary>Number, container ref or no., order and invoice numbers, item code, delivery note no., supplier, movement no.</summary>
    public string? Search { get; init; }

    /// <summary>Draft, Posted, Cancelled or the code 1–3.</summary>
    public string? Status { get; init; }

    /// <summary>Container, Order, Invoice or Manual.</summary>
    public string? SourceKind { get; init; }

    public int? BranchId { get; init; }

    /// <summary>The header's supplier or a line's (a container of several suppliers).</summary>
    public int? SupplierId { get; init; }

    public int? WarehouseId { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public int? ContainerId { get; init; }
    public int? PurchaseOrderId { get; init; }

    /// <summary>The source invoice, or an invoice the received pieces are matched to.</summary>
    public int? InvoiceId { get; init; }

    public int? MovementId { get; init; }
    public bool? IsAuto { get; init; }

    /// <summary>A line received differently from what was expected, or settled short.</summary>
    public bool WithDifferences { get; init; }

    /// <summary>Posted, with received pieces not matched to posted invoices yet.</summary>
    public bool ReceivedNotInvoiced { get; init; }

    /// <summary>Draft container receipts whose container's Delivery is completed: at the warehouse, not in stock.</summary>
    public bool DeliveredNotReceived { get; init; }

    /// <summary>Drafts of any source: nothing of them is in stock yet (the menu count's list).</summary>
    public bool NotReceived { get; init; }

    /// <summary>DocumentNumber, DocumentDate, SupplierName, Status, ReceivedBase, ValueBase, CreatedAtUtc, PostedAtUtc.</summary>
    public string SortBy { get; init; } = "DocumentDate";

    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

/// <summary>The draft goods receipts, for the menu count (hidden at 0) and its tooltip.</summary>
public sealed class GoodsReceiptWaitingDto
{
    public int DraftCount { get; init; }

    /// <summary>Drafts made by the completion of a Delivery movement.</summary>
    public int AutoDraftCount { get; init; }

    /// <summary>Container drafts whose warehouse is still to choose.</summary>
    public int WithoutWarehouseCount { get; init; }

    public DateTime? OldestDraftDate { get; init; }
    public DateTime? OldestCreatedAtUtc { get; init; }
}

/// <summary>
/// When goods receipts started (purchase.GoodsReceiptSwitch, script 65): the date the purchase invoice list's banner
/// names - "Since {date}, posting a supplier invoice no longer adds stock". Null before the switch.
/// </summary>
public sealed class GoodsReceiptSwitchDto
{
    public DateTime? SwitchedAtUtc { get; init; }
}

/* ── one receipt ──────────────────────────────────────────────────────────────────────────────── */

/// <summary>
/// One goods receipt (purchase.usp_GoodsReceipt_Get): the header, the lines, which posted invoice lines pay for the
/// received pieces, the history of their cost, the files and the audit.
///
/// THE REFUSALS ARE WRITTEN ONCE, IN SQL: <see cref="PostBlockedReason"/>, <see cref="CancelBlockedReason"/>,
/// <see cref="DeleteBlockedReason"/> and <see cref="EditBlockedReason"/> are the very sentences Post, Cancel and Delete
/// would refuse with, so a disabled button and a refused click say the same thing.
/// </summary>
public sealed record GoodsReceiptDto
{
    public int Id { get; init; }
    public int DocumentTypeId { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;

    /// <summary>An inactive GRN type still takes drafts; posting one is refused.</summary>
    public bool DocumentTypeIsActive { get; init; }

    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public byte Status { get; init; }
    public string StatusName { get; init; } = string.Empty;
    public string SourceKind { get; init; } = string.Empty;
    public bool IsAuto { get; init; }

    public int BranchId { get; init; }
    public string? BranchCode { get; init; }
    public string? BranchName { get; init; }

    /// <summary>"Receive into": every line of a container receipt; the default of the lines of the others.</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public bool? WarehouseIsActive { get; init; }

    /// <summary>The warehouse belongs to the branch (of the container, for a container receipt); null without a warehouse.</summary>
    public bool? WarehouseInBranch { get; init; }

    public int? SupplierId { get; init; }
    public string? SupplierCode { get; init; }
    public string? SupplierName { get; init; }

    /// <summary>The supplier's name, or "Several suppliers" on a container of several suppliers' orders.</summary>
    public string? SupplierDisplayName { get; init; }

    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public string? SealNo { get; init; }
    public string? TruckNo { get; init; }
    public string? WaybillNo { get; init; }
    public byte? ContainerStatus { get; init; }
    public string? ContainerStatusName => ContainerStatus is { } status ? Logistics.ContainerStatus.Name(status) : null;
    public int? ContainerBranchId { get; init; }

    /// <summary>The container's own "Warehouse (offloading destination)": a draft keeps its own "Receive into".</summary>
    public int? ContainerWarehouseId { get; init; }

    public string? ContainerWarehouseCode { get; init; }
    public int? PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
    public int? PurchaseInvoiceId { get; init; }
    public string? PurchaseInvoiceNumber { get; init; }

    /// <summary>The Delivery-stage movement whose completion created the draft (<see cref="IsAuto"/>).</summary>
    public int? MovementId { get; init; }

    public string? MovementNo { get; init; }
    public DateTime? MovementEndDate { get; init; }
    public string? MovementTypeName { get; init; }
    public string? MovementStage { get; init; }
    public string? MovementFromName { get; init; }
    public string? MovementToName { get; init; }

    /// <summary>The container's latest completed Delivery: goods cannot be received before it ("Delivered").</summary>
    public int? DeliveryMovementId { get; init; }

    public string? DeliveryMovementNo { get; init; }
    public DateTime? DeliveredDate { get; init; }
    public string? DeliveryPlaceName { get; init; }

    /// <summary>The supplier's delivery note no.</summary>
    public string? SupplierReference { get; init; }

    public string? Notes { get; init; }
    public int LineCount { get; init; }
    public int TotalExpectedBase { get; init; }
    public int TotalReceivedBase { get; init; }

    /// <summary>Pieces settled short (on a draft: what posting it would settle).</summary>
    public int TotalShortBase { get; init; }

    public int TotalInvoicedBase { get; init; }

    /// <summary>Σ received × cost at receipt, fixed at posting.</summary>
    public decimal ValueAtReceiptBase { get; init; }

    /// <summary>The value now, after the cost adjustments; an estimate on a draft (<see cref="IsValueEstimate"/>).</summary>
    public decimal CurrentValueBase { get; init; }

    public bool IsValueEstimate { get; init; }
    public string? BaseCurrencyCode { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public int? PostedBy { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public int? CancelledBy { get; init; }
    public string? CancelledByName { get; init; }
    public string? CancelReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public int? UpdatedBy { get; init; }
    public string? UpdatedByName { get; init; }

    public bool CanEdit { get; init; }
    public bool CanPost { get; init; }
    public bool CanCancel { get; init; }
    public bool CanDelete { get; init; }
    public string? EditBlockedReason { get; init; }
    public string? PostBlockedReason { get; init; }
    public string? CancelBlockedReason { get; init; }
    public string? DeleteBlockedReason { get; init; }

    /// <summary>When goods receipts started ("Posted before goods receipts ({date})"); null before the switch.</summary>
    public DateTime? SwitchedAtUtc { get; init; }

    public byte[] RowVersion { get; init; } = [];

    public IReadOnlyList<GoodsReceiptLineDto> Lines { get; init; } = [];
    public IReadOnlyList<GoodsReceiptMatchDto> Matches { get; init; } = [];
    public IReadOnlyList<GoodsReceiptCostChangeDto> CostChanges { get; init; } = [];
    public IReadOnlyList<DocumentFileDto> Files { get; init; } = [];
    public IReadOnlyList<GoodsReceiptAuditDto> Audit { get; init; } = [];
}

/// <summary>
/// One line of a goods receipt. A CONTAINER LINE'S COST IS THE CONTAINER LINE'S (its FOB, its posted charges ÷ what
/// arrived, its landed cost), never copied: a late container charge counts once.
/// </summary>
public sealed class GoodsReceiptLineDto
{
    public int Id { get; init; }
    public int GoodsReceiptId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int ItemUnitId { get; init; }
    public string? UnitTypeName { get; init; }
    public string? SkuCode { get; init; }
    public int PackingFormula { get; init; }

    /// <summary>Received, in the line's unit.</summary>
    public int Quantity { get; init; }

    /// <summary>Received pieces.</summary>
    public int QuantityBase { get; init; }

    /// <summary>Container: the loaded pieces; order or invoice: what was still to receive when the draft was saved.</summary>
    public int? ExpectedQuantityBase { get; init; }

    public int? DifferenceBase { get; init; }

    /// <summary>SHORT, DAMAGED, MISSING, LOADCOUNT or OTHER (<see cref="GoodsReceiptReasonCodes"/>).</summary>
    public string? VarianceReasonCode { get; init; }

    public string? VarianceReasonName { get; init; }

    /// <summary>The free note of the reason.</summary>
    public string? VarianceReason { get; init; }

    /// <summary>"Nothing more will come" on a line of an order: the rest of the order line is settled.</summary>
    public bool CloseShort { get; init; }

    /// <summary>Pieces settled short (on a draft: what posting it would settle).</summary>
    public int SettledShortBase { get; init; }

    public int? WarehouseId { get; init; }
    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public int? SupplierId { get; init; }
    public string? SupplierCode { get; init; }
    public string? SupplierName { get; init; }
    public int? PurchaseOrderId { get; init; }
    public string? OrderNumber { get; init; }
    public int? PoLineId { get; init; }
    public int? PoLineNumber { get; init; }
    public int? OrderedBase { get; init; }
    public string? OrderUnitTypeName { get; init; }
    public int? OrderPackingFormula { get; init; }
    public int? InvoiceLineId { get; init; }
    public int? InvoiceId { get; init; }
    public string? InvoiceNumber { get; init; }
    public int? InvoiceLineNumber { get; init; }
    public int? ContainerLineId { get; init; }
    public int? ContainerLineNumber { get; init; }
    public int? LoadedBase { get; init; }
    public DateTime? ExpiryDate { get; init; }

    /// <summary>Order price per piece in base currency, frozen at posting.</summary>
    public decimal? PoFobBase { get; init; }

    /// <summary>The order price per piece (frozen, or as it stands on a draft).</summary>
    public decimal? OrderPriceBase { get; init; }

    /// <summary>The typed cost per piece of a line without an order.</summary>
    public decimal? ManualUnitCostBase { get; init; }

    /// <summary>Current FOB per piece (the container line's for a container line).</summary>
    public decimal? FobCostBase { get; init; }

    /// <summary>Current charges per piece (the container line's posted charges ÷ received for a container line).</summary>
    public decimal? ChargesBase { get; init; }

    /// <summary>Current landed cost per piece.</summary>
    public decimal? UnitCostBase { get; init; }

    /// <summary>The cost is an estimate (a draft).</summary>
    public bool IsCostEstimate { get; init; }

    /// <summary>The cost written on the stock movement at posting.</summary>
    public decimal? CostAtReceiptBase { get; init; }

    /// <summary>Order | Invoice | Mixed | Manual: where the current cost comes from.</summary>
    public string? CostSource { get; init; }

    public string? CostSourceName { get; init; }

    /// <summary>Received pieces matched to posted supplier invoices.</summary>
    public int InvoicedBase { get; init; }

    public int NotInvoicedBase { get; init; }

    /// <summary>Received × current cost.</summary>
    public decimal? ValueBase { get; init; }

    public string? Notes { get; init; }
    public decimal? ItemLastCost { get; init; }
    public decimal? ItemAverageCost { get; init; }
}

/// <summary>Which posted invoice line pays for which received pieces of a line.</summary>
public sealed class GoodsReceiptMatchDto
{
    public int GoodsReceiptLineId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public int InvoiceLineId { get; init; }
    public int InvoiceId { get; init; }
    public string? InvoiceNumber { get; init; }
    public DateTime? InvoiceDate { get; init; }
    public DateTime? InvoicePostedAtUtc { get; init; }
    public int InvoiceLineNumber { get; init; }
    public int QuantityBase { get; init; }
    public decimal? InvoiceFobBase { get; init; }
    public decimal? InvoiceUnitCostBase { get; init; }
    public DateTime MatchedAtUtc { get; init; }
}

/// <summary>
/// One change of the cost of a received line: an invoice or a landed cost adjustment posted or cancelled, a receipt
/// posted or cancelled, or pieces that filled a negative stock. AMOUNT = INVENTORY + COST OF SALES: the part still in
/// company stock changed the average cost, the rest went to cost of sales.
/// </summary>
public sealed class GoodsReceiptCostChangeDto
{
    public int Id { get; init; }
    public int GoodsReceiptLineId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public DateTime ChangedAtUtc { get; init; }

    /// <summary>PINV, PINVCANCEL, LCA, LCACANCEL, GRNPOST, GRNCANCEL or NEGSTOCK.</summary>
    public string CauseKind { get; init; } = string.Empty;

    public string CauseName => CauseKind switch
    {
        "PINV" => "Invoice posted",
        "PINVCANCEL" => "Invoice cancelled",
        "LCA" => "Landed cost adjustment posted",
        "LCACANCEL" => "Landed cost adjustment cancelled",
        "GRNPOST" => "Goods receipt posted",
        "GRNCANCEL" => "Goods receipt cancelled",
        "NEGSTOCK" => "Sold before it was received",
        _ => CauseKind,
    };

    /// <summary>The invoice, landed cost adjustment or goods receipt that caused it.</summary>
    public int? CauseId { get; init; }

    public string? CauseNumber { get; init; }
    public int ReceivedBase { get; init; }
    public decimal InStockBase { get; init; }
    public decimal? FobBefore { get; init; }
    public decimal? FobAfter { get; init; }
    public decimal? UnitCostBefore { get; init; }
    public decimal? UnitCostAfter { get; init; }
    public decimal AmountBase { get; init; }
    public decimal InventoryBase { get; init; }
    public decimal CogsBase { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class GoodsReceiptAuditDto
{
    public long Id { get; init; }

    /// <summary>Created, Updated, Posted, Cancelled, CostAdjusted, FileAdded, FileUpdated, FileDeleted.</summary>
    public string Action { get; init; } = string.Empty;

    public string? Details { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/* ── saving a draft ───────────────────────────────────────────────────────────────────────────── */

/// <summary>
/// One line of a draft, in the column order of purchase.tvp_GoodsReceiptLine. A container line is in pieces (its base
/// unit), 0 to the loaded pieces, with a reason when it differs; a local line (order, invoice, manual) receives more
/// than 0, or 0 with "Nothing more will come" on a line of an order. EVERY LINE SENT IS SAVED OR REFUSED, NEVER DROPPED:
/// a line of 0 that is neither is refused by the procedure with its "Line N (item)" sentence, N being its place in the
/// request - the row the page shows it on.
/// </summary>
public sealed class GoodsReceiptSaveLineRequest
{
    /// <summary>Ignored: the lines are numbered 1..n in the order sent.</summary>
    public int? LineNumber { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemId { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemUnitId { get; init; }

    /// <summary>Received, in the unit.</summary>
    [Range(0, int.MaxValue)]
    public int Quantity { get; init; }

    /// <summary>The line's warehouse; null = the header's. Container receipts: always the header's.</summary>
    public int? WarehouseId { get; init; }

    public int? PoLineId { get; init; }
    public int? InvoiceLineId { get; init; }
    public int? ContainerLineId { get; init; }

    /// <summary>Recomputed by the procedure (loaded pieces, or what is still to receive); informative.</summary>
    public int? ExpectedQuantityBase { get; init; }

    /// <summary>SHORT, DAMAGED, MISSING, LOADCOUNT or OTHER.</summary>
    [StringLength(20)]
    public string? VarianceReasonCode { get; init; }

    [StringLength(300)]
    public string? VarianceReason { get; init; }

    /// <summary>"Nothing more will come" (a line of an order; a reason required).</summary>
    public bool CloseShort { get; init; }

    /// <summary>The typed cost per piece of a line without an order; null = the item's last cost.</summary>
    [Range(0, double.MaxValue)]
    public decimal? ManualUnitCostBase { get; init; }

    public DateOnly? ExpiryDate { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>
/// POST (a new draft, of any source) and PUT (a draft) of api/purchase/goods-receipts. On a new draft the source is
/// <see cref="SourceKind"/>, or what the ids say (a container, an invoice, order lines, else Manual); the source of a
/// draft never changes afterwards (63000).
/// </summary>
public sealed class GoodsReceiptSaveRequest
{
    /// <summary>A new draft: Container, Order, Invoice or Manual; null = from the ids.</summary>
    [StringLength(10)]
    public string? SourceKind { get; init; }

    public int? ContainerId { get; init; }

    /// <summary>Informative: the order is taken from the lines.</summary>
    public int? PurchaseOrderId { get; init; }

    public int? PurchaseInvoiceId { get; init; }

    /// <summary>The date received; null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    /// <summary>Manual: the branch (else the warehouse's); otherwise the source's.</summary>
    public int? BranchId { get; init; }

    /// <summary>"Receive into": every line of a container receipt, the default of the other lines.</summary>
    public int? WarehouseId { get; init; }

    /// <summary>Manual: required; otherwise checked against the source.</summary>
    public int? SupplierId { get; init; }

    /// <summary>The supplier's delivery note no.</summary>
    [StringLength(100)]
    public string? SupplierReference { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<GoodsReceiptSaveLineRequest> Lines { get; init; } = [];

    public string? RowVersion { get; init; }
}

public sealed class GoodsReceiptPostRequest
{
    public string? RowVersion { get; init; }
}

public sealed class GoodsReceiptCancelRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

/* ── "Receive goods..." ───────────────────────────────────────────────────────────────────────── */

/// <summary>One line of "Receive goods..." on an order: the pieces received now on an order line.</summary>
public sealed class ReceiveFromOrderLineRequest
{
    [Range(1, int.MaxValue)]
    public int PoLineId { get; init; }

    /// <summary>Pieces received now (0 only with <see cref="CloseShort"/>; lines of 0 otherwise are left out).</summary>
    [Range(0, int.MaxValue)]
    public int QuantityBase { get; init; }

    /// <summary>Null = the request's, else the order line's.</summary>
    public int? WarehouseId { get; init; }

    /// <summary>"Nothing more will come": the rest of the order line is settled (a reason required).</summary>
    public bool CloseShort { get; init; }

    /// <summary>SHORT, DAMAGED, MISSING, LOADCOUNT or OTHER.</summary>
    [StringLength(20)]
    public string? ReasonCode { get; init; }

    /// <summary>The free note of the reason.</summary>
    [StringLength(300)]
    public string? Reason { get; init; }

    /// <summary>Null = the order line's.</summary>
    public DateOnly? ExpiryDate { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>
/// "Receive goods..." on a purchase order (posted or closed), and "+ New › From a purchase order...". No lines = every
/// order line with something to receive outside containers. <see cref="Post"/> posts the draft at once (with the post
/// permission).
/// </summary>
public sealed class ReceiveFromOrderRequest
{
    [Range(1, int.MaxValue)]
    public int PurchaseOrderId { get; init; }

    /// <summary>The date received; null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    [StringLength(100)]
    public string? SupplierReference { get; init; }

    /// <summary>"Receive into" for the lines that name none; null = each order line's.</summary>
    public int? WarehouseId { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<ReceiveFromOrderLineRequest>? Lines { get; init; }

    public bool Post { get; init; }
}

/// <summary>One line of "Receive goods..." on a posted invoice: the pieces received now on an invoice line.</summary>
public sealed class ReceiveFromInvoiceLineRequest
{
    [Range(1, int.MaxValue)]
    public int InvoiceLineId { get; init; }

    /// <summary>Pieces received now (0 only with <see cref="CloseShort"/>; lines of 0 otherwise are left out).</summary>
    [Range(0, int.MaxValue)]
    public int QuantityBase { get; init; }

    /// <summary>Null = the request's, else the invoice line's.</summary>
    public int? WarehouseId { get; init; }

    /// <summary>"Nothing more will come" on an invoice line of an order (a reason required).</summary>
    public bool CloseShort { get; init; }

    [StringLength(20)]
    public string? ReasonCode { get; init; }

    [StringLength(300)]
    public string? Reason { get; init; }

    /// <summary>Null = the invoice line's, else the order line's.</summary>
    public DateOnly? ExpiryDate { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>
/// "Receive goods..." on a posted purchase invoice, for its lines not linked to a container. No lines = every such line
/// with something to receive. <see cref="Post"/> posts the draft at once (with the post permission).
/// </summary>
public sealed class ReceiveFromInvoiceRequest
{
    [Range(1, int.MaxValue)]
    public int InvoiceId { get; init; }

    public DateOnly? DocumentDate { get; init; }

    [StringLength(100)]
    public string? SupplierReference { get; init; }

    public int? WarehouseId { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<ReceiveFromInvoiceLineRequest>? Lines { get; init; }

    public bool Post { get; init; }
}

/// <summary>One container line as counted at the gate.</summary>
public sealed class ReceiveContainerLineRequest
{
    [Range(1, int.MaxValue)]
    public int ContainerLineId { get; init; }

    /// <summary>Pieces received, 0 to the loaded pieces.</summary>
    [Range(0, int.MaxValue)]
    public int QuantityBase { get; init; }

    /// <summary>Required when the received pieces differ from the loaded ones: SHORT, DAMAGED, MISSING, LOADCOUNT or OTHER.</summary>
    [StringLength(20)]
    public string? VarianceReasonCode { get; init; }

    [StringLength(300)]
    public string? VarianceReason { get; init; }

    public DateOnly? ExpiryDate { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>
/// "Receive goods..." on a container (status Confirmed to Cleared, no receipt yet), and "+ New › From a container...".
/// No lines = every container line received as loaded. <see cref="Post"/> posts the draft at once (with the post
/// permission).
/// </summary>
public sealed class ReceiveContainerRequest
{
    [Range(1, int.MaxValue)]
    public int ContainerId { get; init; }

    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    /// <summary>"Receive into"; null = the container's warehouse when it is active and of its branch, else to choose.</summary>
    public int? WarehouseId { get; init; }

    public IReadOnlyList<ReceiveContainerLineRequest>? Lines { get; init; }

    public bool Post { get; init; }
}

/// <summary>A refusal kept next to a success: the draft was created, its posting was refused.</summary>
public sealed class GoodsReceiptRefusalDto
{
    public string Code { get; init; } = string.Empty;
    public string Message { get; init; } = string.Empty;
}

/// <summary>
/// The answer of from-order / from-invoice / from-container: the receipt created, posted when asked and allowed.
/// A REFUSED POSTING LEAVES THE DRAFT: <see cref="PostRefusal"/> says why, and the page opens the draft to fix it.
/// </summary>
public sealed class GoodsReceiptCreatedDto
{
    public int Id { get; init; }

    /// <summary>Set when it was posted.</summary>
    public string? DocumentNumber { get; init; }

    public byte Status { get; init; }
    public string StatusName => GoodsReceiptStatus.Name(Status);
    public bool Posted => Status == GoodsReceiptStatus.Posted;

    /// <summary>"Draft goods receipt created." / "Goods receipt GRN-... posted." / "...; not posted: {reason}".</summary>
    public string Message { get; init; } = string.Empty;

    public GoodsReceiptRefusalDto? PostRefusal { get; init; }
}

/* ── what can be received (the dialogs) ───────────────────────────────────────────────────────── */

/// <summary>GET api/purchase/goods-receipts/receivable: one of the four.</summary>
public sealed class ReceivableQuery
{
    public int? PurchaseOrderId { get; init; }
    public int? InvoiceId { get; init; }

    /// <summary>"+ New › From a purchase order...": the supplier's posted or closed orders with something to receive.</summary>
    public int? SupplierId { get; init; }

    public int? ContainerId { get; init; }
}

/// <summary>
/// One line of a "Receive goods..." dialog, in pieces. ToReceive and the rest are the procedures' own figures
/// (purchase.fn_PoLine_Progress, fn_InvoiceLine_ToReceive): the dialog proposes <see cref="DefaultReceiveBase"/>, and
/// posting caps an order line at <see cref="MaxOutsideBase"/>.
/// </summary>
public sealed class ReceivableLineDto
{
    /// <summary>Order | Invoice | Container: the document the line belongs to.</summary>
    public string SourceKind { get; init; } = string.Empty;

    /// <summary>The order, invoice or container.</summary>
    public int DocumentId { get; init; }

    public string? DocumentNumber { get; init; }
    public int LineNumber { get; init; }

    public int? PurchaseOrderId { get; init; }
    public string? OrderNumber { get; init; }
    public int? PoLineId { get; init; }
    public int? PoLineNumber { get; init; }
    public int? InvoiceId { get; init; }
    public string? InvoiceNumber { get; init; }
    public int? InvoiceLineId { get; init; }
    public int? ContainerId { get; init; }
    public int? ContainerLineId { get; init; }

    public int? SupplierId { get; init; }
    public string? SupplierCode { get; init; }
    public string? SupplierName { get; init; }

    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>The line's unit on its document.</summary>
    public int ItemUnitId { get; init; }

    public string? UnitTypeName { get; init; }
    public int PackingFormula { get; init; }

    /// <summary>The item's base unit (pieces): what the quantities here are in.</summary>
    public int? BaseItemUnitId { get; init; }

    public string? BaseUnitTypeName { get; init; }

    /// <summary>The line's warehouse: the default "Receive into".</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public DateTime? ExpiryDate { get; init; }

    /// <summary>Order line: ordered. Invoice line: its order line's ordered pieces.</summary>
    public int? OrderedBase { get; init; }

    /// <summary>Order line: invoiced. Invoice line: its pieces.</summary>
    public int? InvoicedBase { get; init; }

    /// <summary>Received by goods receipts (and before them).</summary>
    public int ReceivedBase { get; init; }

    /// <summary>Order line: settled short.</summary>
    public int ShortBase { get; init; }

    /// <summary>Order line: loaded in containers not received yet (received with their containers).</summary>
    public int InContainersBase { get; init; }

    /// <summary>On draft goods receipts already.</summary>
    public int InDraftReceiptsBase { get; init; }

    /// <summary>What is still to receive here: ordered - received - short - in containers - in drafts (an order line).</summary>
    public int ToReceiveBase { get; init; }

    /// <summary>Order line: the posting cap outside containers (settled pieces that turn up later included).</summary>
    public int? MaxOutsideBase { get; init; }

    /// <summary>Order line: what Shortages counts as still to come.</summary>
    public int? OutstandingBase { get; init; }

    /// <summary>Invoice line: returned.</summary>
    public int? ReturnedBase { get; init; }

    /// <summary>Container line: loaded (= expected).</summary>
    public int? LoadedBase { get; init; }

    /// <summary>What the dialog starts with: 0 on an order or invoice shipped in containers, else <see cref="ToReceiveBase"/>.</summary>
    public int DefaultReceiveBase { get; init; }

    /// <summary>The price per piece in base currency: the order's (container and order lines) or the invoice's.</summary>
    public decimal? UnitPriceBase { get; init; }
}

/// <summary>An order or an invoice of the dialog, with its totals.</summary>
public sealed class ReceivableDocumentDto
{
    /// <summary>Order | Invoice.</summary>
    public string SourceKind { get; init; } = string.Empty;

    public int Id { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }

    /// <summary>The purchase document status: 2 posted (an approved order), 4 closed...</summary>
    public byte Status { get; init; }

    public int BranchId { get; init; }
    public string? BranchCode { get; init; }
    public string? BranchName { get; init; }
    public int? WarehouseId { get; init; }
    public string? WarehouseCode { get; init; }
    public int SupplierId { get; init; }
    public string? SupplierCode { get; init; }
    public string? SupplierName { get; init; }

    /// <summary>
    /// An order with containers, or an invoice "Shipped in containers": its goods are received with their containers,
    /// so the dialog starts at 0 with the orange Alert.
    /// </summary>
    public bool ShippedInContainers { get; init; }

    /// <summary>Invoice: posted before goods receipts without "Shipped in containers" - its stock entered when it was posted.</summary>
    public bool ReceivedAtPosting { get; init; }

    public int LineCount { get; init; }
    public int ToReceiveBase { get; init; }
    public int MaxOutsideBase { get; init; }
    public int InContainersBase { get; init; }
    public int InDraftReceiptsBase { get; init; }
}

/// <summary>A container that can be received: "+ New › From a container..." and the container's "Receive goods...".</summary>
public sealed class ReceivableContainerDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public byte Status { get; init; }
    public string StatusName => Logistics.ContainerStatus.Name(Status);
    public int BranchId { get; init; }
    public string? BranchCode { get; init; }
    public string? BranchName { get; init; }

    /// <summary>The container's "Warehouse (offloading destination)".</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }

    /// <summary>
    /// The warehouse is active, of the container's branch and at the bottom of the tree (script 72): the draft takes it
    /// as "Receive into".
    /// </summary>
    public bool? WarehouseInBranch { get; init; }

    /// <summary>The single supplier of its orders; null with "Several suppliers".</summary>
    public int? SupplierId { get; init; }

    public string? SupplierName { get; init; }
    public string? OrderNumbers { get; init; }
    public int LineCount { get; init; }
    public int LoadedBase { get; init; }

    /// <summary>The container's open goods receipt (a draft or the posted one), if any.</summary>
    public int? GoodsReceiptId { get; init; }

    public string? GoodsReceiptNumber { get; init; }
    public byte? GoodsReceiptStatus { get; init; }

    /// <summary>GRN (received with a goods receipt), Offload (offloaded before goods receipts) or null.</summary>
    public string? ReceivedBy { get; init; }

    public string? DeliveryMovementNo { get; init; }
    public DateTime? DeliveredDate { get; init; }
    public string? DeliveryPlaceName { get; init; }

    /// <summary>A movement of the container in progress: posting its receipt is refused until it is completed.</summary>
    public string? MovementInProgressNo { get; init; }

    /// <summary>Status 2–5 and no draft or posted receipt.</summary>
    public bool CanReceive { get; init; }

    /// <summary>Confirmed and never dispatched (status 2): the page warns "has not left the supplier".</summary>
    public bool NotDispatched => Status == 2;
}

/// <summary>
/// The answer of GET .../receivable: the documents (one order, one invoice, or the supplier's orders with something to
/// receive) or the container, and their lines.
/// </summary>
public sealed class ReceivableDto
{
    /// <summary>Order | Invoice | Supplier | Container: what was asked.</summary>
    public string Kind { get; init; } = string.Empty;

    public int? SupplierId { get; init; }
    public string? SupplierCode { get; init; }
    public string? SupplierName { get; init; }
    public IReadOnlyList<ReceivableDocumentDto> Documents { get; init; } = [];
    public ReceivableContainerDto? Container { get; init; }
    public IReadOnlyList<ReceivableLineDto> Lines { get; init; } = [];

    /// <summary>Σ to receive over the lines.</summary>
    public int ToReceiveBase => Lines.Sum(l => l.ToReceiveBase);
}

/// <summary>GET api/purchase/goods-receipts/receivable-containers: the containers "From a container..." offers.</summary>
public sealed class ReceivableContainersQuery
{
    /// <summary>Container ref or no., order number.</summary>
    public string? Search { get; init; }

    public int? BranchId { get; init; }
    public int? SupplierId { get; init; }

    /// <summary>Only the containers whose Delivery movement is completed.</summary>
    public bool DeliveredOnly { get; init; }
}
