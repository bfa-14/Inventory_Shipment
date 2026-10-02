using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/// <summary>
/// The three kinds of the Purchase family. ONE ENGINE, THREE PERMISSION SETS: the tables, the
/// procedures and the page are shared, and the code on the document decides which
/// purchase.orders.* / purchase.invoices.* / purchase.returns.* right a caller has to hold.
/// </summary>
public static class PurchaseDocumentTypes
{
    public const string Order = "PO";
    public const string Invoice = "PINV";
    public const string Return = "PRET";

    public static bool IsKnown(string? code)
        => string.Equals(code, Order, StringComparison.OrdinalIgnoreCase)
           || string.Equals(code, Invoice, StringComparison.OrdinalIgnoreCase)
           || string.Equals(code, Return, StringComparison.OrdinalIgnoreCase);

    /// <summary>The code in its canonical spelling, or null when it is not a purchase type.</summary>
    public static string? Normalize(string? code)
    {
        if (string.Equals(code, Order, StringComparison.OrdinalIgnoreCase)) return Order;
        if (string.Equals(code, Invoice, StringComparison.OrdinalIgnoreCase)) return Invoice;
        if (string.Equals(code, Return, StringComparison.OrdinalIgnoreCase)) return Return;
        return null;
    }
}

/// <summary>
/// Purchase documents have one status more than the others: a posted purchase order is OPEN, and it
/// becomes CLOSED when every line has been received or when somebody closes it by hand.
/// </summary>
public static class PurchaseDocumentStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;
    public const byte CancelledCode = 3;
    public const byte ClosedCode = 4;

    /// <summary>A purchase order sent for approval (script 26): not editable, not posted yet.</summary>
    public const byte PendingApprovalCode = 5;

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Cancelled = "Cancelled";
    public const string Closed = "Closed";
    public const string PendingApproval = "PendingApproval";

    public static string From(byte code) => code switch
    {
        PostedCode => Posted,
        CancelledCode => Cancelled,
        ClosedCode => Closed,
        PendingApprovalCode => PendingApproval,
        _ => Draft,
    };

    public static byte? ToCode(string? status) => status switch
    {
        "1" or Draft => DraftCode,
        "2" or Posted => PostedCode,
        "3" or Cancelled => CancelledCode,
        "4" or Closed => ClosedCode,
        "5" or PendingApproval => PendingApprovalCode,
        _ => null,
    };
}

public sealed class PurchaseDocumentListDto
{
    public int Id { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public short StockDirection { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public DateTime? ExpectedDate { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public decimal ExchangeRate { get; init; }
    public string? SupplierReference { get; init; }

    /// <summary>Filled once usp_PurchaseDocument_Search returns it; null before.</summary>
    public string? ExporterReference { get; init; }

    public string? CommercialInvoiceNo { get; init; }

    /// <summary>1 = on posting, 2 = on container offload.</summary>
    public byte ReceiptMode { get; init; } = PurchaseReceiptModes.OnPosting;

    public string Status { get; init; } = PurchaseDocumentStatus.Draft;
    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }
    public int? SourceDocumentId { get; init; }
    public string? SourceDocumentNumber { get; init; }

    /// <summary>Orders only: how much of the ordered quantity has been invoiced, 0–100.</summary>
    public decimal? ReceivedPercent { get; init; }

    /// <summary>Supplier invoices only: the item it holds (the one of its first line). Null for orders and returns.</summary>
    public int? ItemId { get; init; }

    public string? ItemCode { get; init; }
    public string? ItemName { get; init; }

    /// <summary>Supplier invoices only: how many items it holds — more than 1 for a draft made before one item per invoice.</summary>
    public int? ItemCount { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public DateTime? ClosedAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class PurchaseDocumentLineDto
{
    public int Id { get; init; }
    public int LineNo { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int ItemUnitId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public string? SkuCode { get; init; }
    public string? Barcode { get; init; }
    public int PackingFormula { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public DateTime? ExpiryDate { get; init; }
    public int Quantity { get; init; }
    public decimal QuantityBase { get; init; }
    public decimal UnitPrice { get; init; }
    public decimal DiscountPercent { get; init; }
    public decimal LineDiscount { get; init; }
    public decimal LineTotal { get; init; }

    /// <summary>The LANDED cost per base unit in the base currency, written by the posting (FOB + allocated charges).</summary>
    public decimal? UnitCostBase { get; init; }

    /// <summary>The same figure under the name the costing uses. Kept beside it so a column can say "Landed" without arithmetic.</summary>
    public decimal? LandedCostBase { get; init; }

    /// <summary>What the supplier charged, per base unit, before any of the charges around it.</summary>
    public decimal? FobCostBase { get; init; }

    /// <summary>The charges this line took, in the base currency — the difference between FOB and landed, times the quantity.</summary>
    public decimal AllocatedChargesBase { get; init; }

    public decimal ReceivedQuantityBase { get; init; }
    public decimal ReturnedQuantityBase { get; init; }

    /// <summary>Orders: still to receive; invoices: still returnable; returns: null.</summary>
    public decimal? RemainingBase { get; init; }

    /// <summary>Orders: what the supplier has shipped so far (base units), recorded with "Mark as shipped".</summary>
    public decimal ShippedQuantityBase { get; init; }

    /// <summary>
    /// Invoices: loaded on containers In Transit / At Port / Cleared and not yet received — the
    /// quantity on its way, which the shortage plan counts as Transit.
    /// </summary>
    public decimal TransitBase { get; init; }

    /// <summary>Invoices: what containers that are not cancelled hold of this line, in base units.</summary>
    public int AllocatedToContainersBase { get; init; }

    /// <summary>Orders: what is still free to load into a container (ordered − loaded − invoiced directly); null on invoices and returns.</summary>
    public int? AvailableForContainerBase { get; init; }

    /// <summary>Orders: in invoices made straight from the order, without a container (draft or posted).</summary>
    public int? InvoicedDirectBase { get; init; }

    /* Invoices from containers: every line points to ONE container line. */
    public int? ContainerLineId { get; init; }
    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }

    /// <summary>The container status code 1–8 (see Logistics.ContainerStatus).</summary>
    public byte? ContainerStatus { get; init; }

    /// <summary>The posted container charges that fall on this invoice line (its share of the container line's).</summary>
    public decimal? ContainerChargesBase { get; init; }

    /// <summary>FOB + container charges per unit; final once the container is offloaded.</summary>
    public decimal? EstimatedLandedCostBase { get; init; }

    public int? ImportRowNumber { get; init; }
    public string? Notes { get; init; }
    public int? SourceLineId { get; init; }
    public decimal OnHandBase { get; init; }
    public decimal? ItemLastCost { get; init; }
    public decimal? ItemAverageCost { get; init; }

    /// <summary>The item's FOB cost as it stands now — what the next invoice would start from.</summary>
    public decimal? ItemFobCost { get; init; }
}

public sealed class PurchaseDocumentFileDto
{
    public int Id { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class PurchaseDocumentAuditDto
{
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>A document this one came from ("Source") or one made from it ("Child").</summary>
public sealed class LinkedPurchaseDocumentDto
{
    public string Relation { get; init; } = string.Empty;
    public int Id { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public string Status { get; init; } = PurchaseDocumentStatus.Draft;
    public decimal TotalAmount { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
}

/// <summary>
/// A container of the document — the 7th result set of usp_PurchaseDocument_Get: for an order the
/// containers carrying its lines, for an invoice the containers its lines come from.
/// </summary>
public sealed class PurchaseInvoiceContainerDto
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }

    /// <summary>The container status code 1–8 (see Logistics.ContainerStatus).</summary>
    public byte Status { get; init; }

    public string StatusName => Logistics.ContainerStatus.Name(Status);
    public DateTime? DispatchDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public string? CurrentLocation { get; init; }
    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }

    /// <summary>Of THIS document, loaded on that container.</summary>
    public int AllocatedBase { get; init; }

    public int ReceivedBase { get; init; }

    /// <summary>Of this document's quantity on the container, what POSTED invoices cover.</summary>
    public int InvoicedBase { get; init; }

    public int ContainerTypeId { get; init; }
    public string ContainerTypeCode { get; init; } = string.Empty;

    /// <summary>The order the container was created from.</summary>
    public int? PurchaseOrderId { get; init; }
}

/// <summary>When a purchase invoice puts its goods into stock.</summary>
public static class PurchaseReceiptModes
{
    /// <summary>Stock enters when the invoice is posted (local purchases).</summary>
    public const byte OnPosting = 1;

    /// <summary>Stock enters when the container carrying it is offloaded (imports). Forced once the invoice is loaded.</summary>
    public const byte OnContainerOffload = 2;
}

public sealed class PurchaseDocumentDto
{
    public int Id { get; init; }
    public int DocumentTypeId { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public short StockDirection { get; init; }
    public bool NumberOnPost { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public DateTime? ExpectedDate { get; init; }
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public string? SupplierPhone { get; init; }
    public string? SupplierEmail { get; init; }
    public string? SupplierAddress { get; init; }

    /* THE DOCUMENT CURRENCY IS THE SUPPLIER'S BY DEFAULT and is snapshotted with its rate: a supplier
       whose currency is changed later must not restate an invoice already booked. */
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }
    public byte RateType { get; init; }
    public decimal ExchangeRate { get; init; }
    public string? BaseCurrencyCode { get; init; }

    public string? SupplierReference { get; init; }

    /// <summary>The exporter's reference on the supplier's paperwork (invoices).</summary>
    public string? ExporterReference { get; init; }

    /// <summary>The supplier's commercial invoice number — what the container list and the forwarder quote.</summary>
    public string? CommercialInvoiceNo { get; init; }

    /// <summary>
    /// 1 = stock on posting, 2 = stock on container offload (see <see cref="PurchaseReceiptModes"/>). Chosen on an
    /// invoice since script 43 (<see cref="ShippedInContainers"/>); a line linked to a container forces 2.
    /// </summary>
    public byte ReceiptMode { get; init; } = PurchaseReceiptModes.OnPosting;

    /// <summary>An invoice whose goods enter the stock at the offload of its containers (receipt mode 2).</summary>
    public bool ShippedInContainers => DocumentTypeCode == PurchaseDocumentTypes.Invoice && ReceiptMode == PurchaseReceiptModes.OnContainerOffload;

    public string? Notes { get; init; }
    public string Status { get; init; } = PurchaseDocumentStatus.Draft;

    /// <summary>Invoices: created from containers (its lines point to container lines). The exporter reference is then required to post.</summary>
    public bool IsContainerBound { get; init; }

    /// <summary>Orders: containers carrying its lines (not cancelled); invoices: containers its lines come from.</summary>
    public int ContainerCount { get; init; }

    /// <summary>
    /// Invoices: the containers its pieces fill, summed over its items (pieces / the item's Container unit, 2 decimals);
    /// null when no item has a Container unit, and on orders and returns.
    /// </summary>
    public decimal? ContainersNeeded { get; init; }

    /// <summary>Orders: loaded in containers that are not cancelled, in base units; null on invoices and returns.</summary>
    public int? LoadedBase { get; init; }

    /// <summary>Invoices from containers: the posted container charges (in the landed cost) falling on its lines.</summary>
    public decimal? ContainerChargesBase { get; init; }

    /* Orders: invoicing progress (script 26), in base units. */
    public decimal? OrderedBase { get; init; }
    public decimal? InvoicedBase { get; init; }
    public decimal InDraftInvoicesBase { get; init; }

    /// <summary>Orders: 0 not, 1 partially, 2 fully invoiced (posted invoices); null on invoices and returns.</summary>
    public int? InvoicingStatus { get; init; }
    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }

    /// <summary>The landed charges on the goods, in the base currency: the invoice's own and its posted adjustments'.</summary>
    public decimal TotalChargesBase { get; init; }

    /// <summary>What the goods really cost: TotalAmountBase + TotalChargesBase.</summary>
    public decimal TotalLandedCostBase { get; init; }

    public int? SourceDocumentId { get; init; }
    public string? SourceDocumentNumber { get; init; }
    public string? SourceDocumentTypeCode { get; init; }

    /// <summary>The shortage plan this order was created from (Shortage → PO → Purchase Invoice traceability).</summary>
    public int? SourceShortageId { get; init; }
    public string? SourceShortageNumber { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelledByName { get; init; }
    public string? CancelReason { get; init; }
    public DateTime? ClosedAtUtc { get; init; }
    public string? ClosedByName { get; init; }
    public string? CloseReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /* What the DOCUMENT allows, from its status and kind. Whether this user may is a permission,
       checked separately; both have to be true before a button is offered. */
    public bool CanEdit => Status == PurchaseDocumentStatus.Draft;
    public bool CanPost => Status == PurchaseDocumentStatus.Draft;
    public bool CanDelete => Status == PurchaseDocumentStatus.Draft;

    /// <summary>Posted documents, and closed orders too: cancelling a closed order reverses nothing, it only ends it.</summary>
    public bool CanCancel => Status is PurchaseDocumentStatus.Posted or PurchaseDocumentStatus.Closed;

    /// <summary>Only an open (posted) order can be closed by hand.</summary>
    public bool CanClose => DocumentTypeCode == PurchaseDocumentTypes.Order && Status == PurchaseDocumentStatus.Posted;

    /// <summary>
    /// Charges are typed on a DRAFT invoice; after posting they arrive as a landed cost adjustment
    /// instead. Never on an invoice from containers: an import's charges go on its containers (65020).
    /// </summary>
    public bool CanEditCharges
        => DocumentTypeCode == PurchaseDocumentTypes.Invoice && Status == PurchaseDocumentStatus.Draft && !IsContainerBound;

    /// <summary>A posted local invoice can receive charges that arrived late, through a landed cost adjustment (67012 on an import).</summary>
    public bool CanAdjustLandedCost
        => DocumentTypeCode == PurchaseDocumentTypes.Invoice && Status == PurchaseDocumentStatus.Posted && !IsContainerBound;

    /// <summary>Shipped quantities are recorded on an open order only — the procedure refuses anything else.</summary>
    public bool CanMarkShipped => DocumentTypeCode == PurchaseDocumentTypes.Order && Status == PurchaseDocumentStatus.Posted;

    /// <summary>
    /// An open order with something left to receive becomes a purchase invoice. Since script 43 an order with
    /// containers too: the invoice is "shipped in containers" and is linked to them afterwards.
    /// </summary>
    public bool CanCreateInvoice
        => DocumentTypeCode == PurchaseDocumentTypes.Order
           && Status == PurchaseDocumentStatus.Posted
           && Lines.Any(l => (l.RemainingBase ?? 0) > 0);

    /// <summary>A posted invoice with something not yet returned becomes a purchase return.</summary>
    public bool CanCreateReturn
        => DocumentTypeCode == PurchaseDocumentTypes.Invoice
           && Status == PurchaseDocumentStatus.Posted
           && Lines.Any(l => (l.RemainingBase ?? 0) > 0);

    public IReadOnlyList<PurchaseDocumentLineDto> Lines { get; init; } = [];

    /// <summary>The invoice's own charges AND those of its adjustments, each saying which it came from.</summary>
    public IReadOnlyList<PurchaseChargeDto> Charges { get; init; } = [];

    public IReadOnlyList<PurchaseDocumentFileDto> Files { get; init; } = [];
    public IReadOnlyList<PurchaseDocumentAuditDto> Audit { get; init; } = [];
    public IReadOnlyList<LinkedPurchaseDocumentDto> Linked { get; init; } = [];

    /// <summary>The containers of the order or of the invoice, with what each holds, has invoiced and has received.</summary>
    public IReadOnlyList<PurchaseInvoiceContainerDto> Containers { get; init; } = [];
}

/// <summary>The answer of masterdata.usp_ExchangeRate_Resolve: a currency and its rate on a day.</summary>
public sealed class PurchaseRateResolutionDto
{
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? Symbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }
    public byte RateType { get; init; }

    /// <summary>Null when nothing is defined for that day — a warning on the page, not an error.</summary>
    public decimal? Rate { get; init; }

    public DateTime? RateDate { get; init; }
    public string? BaseCurrencyCode { get; init; }
}

/* ── requests ──────────────────────────────────────────────────────────────────────────────── */

public sealed class SavePurchaseDocumentLineRequest
{
    public int LineNo { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemId { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemUnitId { get; init; }

    /// <summary>The warehouse this line moves stock in. Null falls back to the header's, for callers that send only one.</summary>
    public int? WarehouseId { get; init; }

    public DateOnly? ExpiryDate { get; init; }

    [Range(1, int.MaxValue)]
    public int Quantity { get; init; }

    /// <summary>Null = the item's last cost converted to the document currency (0 when it has none).</summary>
    [Range(0, double.MaxValue)]
    public decimal? UnitPrice { get; init; }

    [Range(0, 100)]
    public decimal? DiscountPercent { get; init; }

    public int? ImportRowNumber { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }

    /// <summary>The order line an invoice line receives, or the invoice line a return line gives back.</summary>
    public int? SourceLineId { get; init; }

    /// <summary>
    /// Invoices from containers: the container line this line invoices. When the invoice comes from
    /// containers EVERY line must send it back on save (the procedure refuses otherwise).
    /// </summary>
    public int? ContainerLineId { get; init; }
}

public sealed class SavePurchaseDocumentRequest
{
    [Required]
    [StringLength(20)]
    public string DocumentTypeCode { get; init; } = string.Empty;

    [Required]
    public DateOnly DocumentDate { get; init; }

    public DateOnly? ExpectedDate { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>
    /// Optional. The warehouse now lives on each LINE; the header keeps one only so that document
    /// lists, filters, reports and exports have one to show. Null = the first line's warehouse.
    /// </summary>
    public int? WarehouseId { get; init; }

    [Range(1, int.MaxValue)]
    public int SupplierId { get; init; }

    /// <summary>Null = the supplier's default currency, else the base currency.</summary>
    public int? CurrencyId { get; init; }

    [Range(1, 3)]
    public byte RateType { get; init; } = RateTypes.Official;

    /// <summary>Null = resolved from the exchange rates for the document date.</summary>
    [Range(0.000001, double.MaxValue)]
    public decimal? ExchangeRate { get; init; }

    [StringLength(100)]
    public string? SupplierReference { get; init; }

    /// <summary>1 on posting, 2 on container offload; null = unchanged (1 on creation). <see cref="ShippedInContainers"/> wins when sent.</summary>
    [Range(1, 2)]
    public byte? ReceiptMode { get; init; }

    /// <summary>
    /// Invoices: "Shipped in containers" = receipt mode 2, off = 1; null = unchanged. Switching it off while a line is
    /// linked to a container is refused (409 RECEIPT_MODE_LOCKED).
    /// </summary>
    public bool? ShippedInContainers { get; init; }

    [StringLength(50)]
    public string? ExporterReference { get; init; }

    [StringLength(50)]
    public string? CommercialInvoiceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public int? SourceDocumentId { get; init; }

    public IReadOnlyList<SavePurchaseDocumentLineRequest> Lines { get; init; } = [];

    public string? RowVersion { get; init; }
}

public sealed class PostPurchaseDocumentRequest
{
    public string? RowVersion { get; init; }
}

public sealed class CancelPurchaseDocumentRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

public sealed class ClosePurchaseDocumentRequest
{
    [StringLength(300)]
    public string? Reason { get; init; }

    public string? RowVersion { get; init; }
}

/// <summary>One line of "Mark as shipped": the TOTAL shipped so far on that line, in base units (0..ordered).</summary>
public sealed class ShippedLineRequest
{
    [Range(1, int.MaxValue)]
    public int LineId { get; init; }

    [Range(0, int.MaxValue)]
    public int ShippedQuantityBase { get; init; }
}

/// <summary>What the supplier has shipped on an open purchase order. NO LINES = EVERYTHING SHIPPED.</summary>
public sealed class MarkShippedRequest
{
    public IReadOnlyList<ShippedLineRequest> Lines { get; init; } = [];
    public string? RowVersion { get; init; }
}

/// <summary>One container line of an invoice from containers, and the pieces to invoice.</summary>
public sealed class ContainerLineQuantityRequest
{
    [Range(1, int.MaxValue)]
    public int ContainerLineId { get; init; }

    [Range(1, int.MaxValue)]
    public int QuantityBase { get; init; }
}

/// <summary>
/// Draft purchase invoices from container lines of one order — ONE PER ITEM (script 45). NO LINES =
/// everything loaded and not yet invoiced.
/// </summary>
public sealed class InvoiceFromContainersRequest
{
    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    public IReadOnlyList<ContainerLineQuantityRequest> Lines { get; init; } = [];

    /// <summary>Copied to every invoice created.</summary>
    [StringLength(50)]
    public string? ExporterReference { get; init; }

    /// <summary>Copied to every invoice created.</summary>
    [StringLength(50)]
    public string? CommercialInvoiceNo { get; init; }
}

/// <summary>Make the next document of the chain (order → invoice, invoice → return) from a posted one.</summary>
public sealed class CreateFromSourceRequest
{
    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    /// <summary>Order → invoices: copied to every invoice created. Ignored for a return.</summary>
    [StringLength(50)]
    public string? ExporterReference { get; init; }

    /// <summary>Order → invoices: copied to every invoice created. Ignored for a return.</summary>
    [StringLength(50)]
    public string? CommercialInvoiceNo { get; init; }
}

/// <summary>One supplier invoice a create or a split made: a supplier invoice holds ONE item (script 45).</summary>
public sealed class CreatedPurchaseInvoiceDto
{
    public int Id { get; init; }
    public int? ItemId { get; init; }
    public string? ItemCode { get; init; }
    public string? ItemName { get; init; }
    public int LineCount { get; init; }
    public int QuantityBase { get; init; }
    public decimal TotalAmount { get; init; }
}

/// <summary>
/// The answer to "create invoice" from an order or from its containers: one draft per item of the selection.
/// <see cref="Id"/> is <see cref="FirstId"/> under the name the pages read before invoices were split by item.
/// </summary>
public sealed class CreatedPurchaseInvoicesDto
{
    public int FirstId { get; init; }

    /// <summary>= <see cref="FirstId"/>: the field the pages opened the new draft with.</summary>
    public int Id => FirstId;

    public IReadOnlyList<CreatedPurchaseInvoiceDto> Invoices { get; init; } = [];

    /// <summary>"3 invoices created, one per item" or "Invoice created".</summary>
    public string Message { get; init; } = string.Empty;

    public static CreatedPurchaseInvoicesDto From(IReadOnlyList<CreatedPurchaseInvoiceDto> invoices) => new()
    {
        FirstId = invoices.Count > 0 ? invoices[0].Id : 0,
        Invoices = invoices,
        Message = invoices.Count == 1 ? "Invoice created" : $"{invoices.Count} invoices created, one per item",
    };
}

/// <summary>Split a draft supplier invoice holding several items (made before script 45) into one invoice per item.</summary>
public sealed class SplitByItemRequest
{
    public string? RowVersion { get; init; }
}

/// <summary>The invoices after a split by item: the original (holding the item of its first line) first.</summary>
public sealed class SplitByItemResultDto
{
    public IReadOnlyList<CreatedPurchaseInvoiceDto> Invoices { get; init; } = [];
}

/// <summary>What the procedures that create from a source answer: the first id, and one row per invoice (none for a return).</summary>
public sealed record CreatedFromSource(int NewId, IReadOnlyList<CreatedPurchaseInvoiceDto> Invoices);

public sealed class PurchaseDocumentQuery
{
    /// <summary>PO, PINV or PRET. Required: the list a user sees is one kind, and each kind is its own permission.</summary>
    public string? DocumentTypeCode { get; init; }

    public string? Search { get; init; }
    public int? BranchId { get; init; }
    public int? WarehouseId { get; init; }
    public int? SupplierId { get; init; }

    /// <summary>Draft, Posted, Cancelled, Closed or the code 1–4.</summary>
    public string? Status { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public string SortBy { get; init; } = "DocumentDate";
    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class ImportCreatePurchaseDocumentsRequest
{
    [Required]
    [StringLength(20)]
    public string DocumentTypeCode { get; init; } = string.Empty;

    [Required]
    public DateOnly DocumentDate { get; init; }

    public DateOnly? ExpectedDate { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    [Range(1, int.MaxValue)]
    public int SupplierId { get; init; }

    public int? CurrencyId { get; init; }

    [Range(1, 3)]
    public byte RateType { get; init; } = RateTypes.Official;

    [Range(0.000001, double.MaxValue)]
    public decimal? ExchangeRate { get; init; }

    [StringLength(100)]
    public string? SupplierReference { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<ImportCreateLine> Lines { get; init; } = [];

    public bool PostImmediately { get; init; }
}
