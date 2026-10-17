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
/// The status of a purchase document, as stored: Draft, Waiting for approval (orders), Posted, Cancelled. A POSTED
/// purchase order is an approved one, and what it SHOWS follows its posted invoices (script 77, the owner's words):
/// Saved (none yet), Partially posted (less than ordered), Posted (everything ordered) - see <see cref="OrderStage"/>.
/// The API keeps "Posted" as the status of every approved order, because every rule that asks "is it approved?" reads
/// that string; the stage travels next to it as InvoicingStatus. Closed (4) is no longer written: script 77 brought the
/// closed orders back, and the constants stay only to read a row from before it.
/// </summary>
public static class PurchaseDocumentStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;
    public const byte CancelledCode = 3;
    /// <summary>No longer written (script 77): purchase orders are not closed any more.</summary>
    public const byte ClosedCode = 4;

    /// <summary>A purchase order sent for approval (script 26): not editable, not posted yet.</summary>
    public const byte PendingApprovalCode = 5;

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Cancelled = "Cancelled";
    public const string Closed = "Closed";
    public const string PendingApproval = "PendingApproval";

    /* (77) What an approved purchase order shows, from InvoicingStatus 0 / 1 / 2 (its posted invoices). */
    public const string Saved = "Saved";
    public const string PartiallyPosted = "PartiallyPosted";

    /// <summary>
    /// The stage of an approved order: <see cref="Saved"/> (0, no posted invoice), <see cref="PartiallyPosted"/> (1) or
    /// <see cref="Posted"/> (2, everything ordered is invoiced). Draft invoices and purchase returns do not change it.
    /// </summary>
    public static string OrderStage(int? invoicingStatus) => invoicingStatus switch
    {
        2 => Posted,
        1 => PartiallyPosted,
        _ => Saved,
    };

    /// <summary>
    /// The words a reader sees for a document's status, for exports: "Waiting for approval", and for an approved order
    /// "Saved", "Partially posted" or "Posted". Invoices and returns keep "Posted".
    /// </summary>
    public static string Label(string status, string documentTypeCode, int? invoicingStatus)
    {
        if (status == Posted && documentTypeCode == PurchaseDocumentTypes.Order)
        {
            status = OrderStage(invoicingStatus);
        }

        return status switch
        {
            PendingApproval => "Waiting for approval",
            PartiallyPosted => "Partially posted",
            _ => status,
        };
    }

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

    /// <summary>1 = not shipped in containers, 2 = "Shipped in containers" (see <see cref="PurchaseReceiptModes"/>).</summary>
    public byte ReceiptMode { get; init; } = PurchaseReceiptModes.OnPosting;

    public string Status { get; init; } = PurchaseDocumentStatus.Draft;

    /// <summary>
    /// (77) Orders: 0 Saved, 1 Partially posted, 2 Posted - how far posted invoices cover it (the stage of an order whose
    /// <see cref="Status"/> is Posted, see <see cref="PurchaseDocumentStatus.OrderStage"/>). Null on invoices and returns.
    /// </summary>
    public int? InvoicingStatus { get; init; }

    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }
    public int? SourceDocumentId { get; init; }
    public string? SourceDocumentNumber { get; init; }

    /// <summary>
    /// Orders only: how much of the ordered quantity has been RECEIVED by goods receipts (and the receipts made before
    /// them), 0–100. Since script 65; before, this column was the invoiced percent, now <see cref="InvoicedPercent"/>.
    /// </summary>
    public decimal? ReceivedPercent { get; init; }

    /// <summary>Orders only: how much of the ordered quantity posted supplier invoices cover, 0–100.</summary>
    public decimal? InvoicedPercent { get; init; }

    /// <summary>
    /// (65) Supplier invoices: posted after goods receipts started - their goods enter stock with goods receipts, the
    /// posting moved no stock. False on drafts (set when posted), on invoices posted before, on orders and returns.
    /// </summary>
    public bool UsesGoodsReceipts { get; init; }

    /// <summary>(65) The "Received" progress: pieces ordered (orders) or invoiced (supplier invoices); null on returns.</summary>
    public int? QuantityBase { get; init; }

    /// <summary>
    /// (65) Pieces received of <see cref="QuantityBase"/>: by goods receipts; an invoice posted with its stock before goods
    /// receipts received everything when it was posted. Null on returns.
    /// </summary>
    public int? ReceivedBase { get; init; }

    /// <summary>Supplier invoices only: the item it holds (the one of its first line). Null for orders and returns.</summary>
    public int? ItemId { get; init; }

    public string? ItemCode { get; init; }
    public string? ItemName { get; init; }

    /// <summary>
    /// Supplier invoices only: how many items it holds. More than 1 for an invoice that may hold several (script 63:
    /// <see cref="PurchaseSettingKeys.OneItemPerInvoice"/> off, or chosen when it was created) or a draft made before
    /// one item per invoice: the list then says "3 items" instead of the item.
    /// </summary>
    public int? ItemCount { get; init; }

    /// <summary>
    /// Supplier invoices only: its mode (script 63), its own or, for an invoice created before, the setting
    /// <see cref="PurchaseSettingKeys.OneItemPerInvoice"/>. True = it holds one item: a draft that holds several (saved
    /// before that rule) is refused by Post (65029) until it is split, and the list flags it. False = it may hold several
    /// items. Null for orders and returns.
    /// </summary>
    public bool? OneItemOnly { get; init; }

    /* (47) Supplier payments - posted purchase invoices only; null on orders, returns, drafts and cancelled ones. */

    /// <summary>What posted supplier payments have paid, in the invoice's currency.</summary>
    public decimal? PaidAmount { get; init; }

    /// <summary>Posted purchase returns made from it, in its currency: they lower what is owed.</summary>
    public decimal? ReturnedAmount { get; init; }

    /// <summary>Total less returns less payments, in the invoice's currency.</summary>
    public decimal? OutstandingAmount { get; init; }

    /// <summary>Unpaid, Partial or Paid.</summary>
    public string? PaymentStatus { get; init; }

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

    /// <summary>
    /// Orders: still to INVOICE; invoices: still returnable - since script 65, for an invoice that uses goods receipts or
    /// is shipped in containers, received - returned (only received goods go back); returns: null.
    /// </summary>
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

    /// <summary>
    /// Orders: what the line has committed outside containers - since script 65 the larger of invoiced outside
    /// containers, and received outside containers + on draft goods receipts (purchase.fn_PoLine_CommittedOutside; its
    /// parts are <see cref="InvoicedOutsideBase"/>, <see cref="ReceivedOutsideBase"/>, <see cref="InDraftReceiptsOutsideBase"/>).
    /// </summary>
    public int? InvoicedDirectBase { get; init; }

    /* (65) GOODS RECEIPTS. Order lines: Invoiced is ReceivedQuantityBase (the old name, its meaning unchanged), Received
       and Short come from goods receipts (purchase.fn_PoLine_Progress). Invoice lines: ReceivedQuantityBase is the pieces
       received (matched to the line) for an invoice that uses goods receipts or is shipped in containers. */

    /// <summary>Orders: pieces received (goods receipts, and the receipts made before them).</summary>
    public int? GoodsReceivedBase { get; init; }

    /// <summary>Orders: pieces settled short - nothing more will come for them.</summary>
    public int? GoodsShortBase { get; init; }

    /// <summary>Orders: loaded in containers not received yet (draft to cleared).</summary>
    public int? InContainersBase { get; init; }

    /// <summary>Orders: on draft goods receipts outside containers. Invoices: on draft goods receipts made from the line.</summary>
    public int? InDraftReceiptsBase { get; init; }

    /// <summary>
    /// What "Receive goods..." proposes. Orders: ordered - received - short - in containers - in draft receipts. Invoices:
    /// invoiced - received - in draft receipts, 0 on a line in a container and on an invoice posted before goods receipts.
    /// Null on returns.
    /// </summary>
    public int? ToReceiveBase { get; init; }

    /// <summary>Orders: the posting cap of a receipt outside containers (ordered - received - in containers).</summary>
    public int? MaxOutsideBase { get; init; }

    /// <summary>Orders: still to come (rule 17), the number Shortages and the item's "On order" count.</summary>
    public int? OutstandingBase { get; init; }

    /// <summary>Orders: invoiced outside containers (draft, posted or closed invoices not shipped in containers).</summary>
    public int? InvoicedOutsideBase { get; init; }

    /// <summary>Orders: received outside containers (posted goods receipts, and invoices that received when posted).</summary>
    public int? ReceivedOutsideBase { get; init; }

    /// <summary>Orders: on draft goods receipts outside containers.</summary>
    public int? InDraftReceiptsOutsideBase { get; init; }

    /* Invoices from containers: every line points to ONE container line. */
    public int? ContainerLineId { get; init; }
    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }

    /// <summary>The container status code 1–8 (see Logistics.ContainerStatus).</summary>
    public byte? ContainerStatus { get; init; }

    /// <summary>The posted container charges that fall on this invoice line (its share of the container line's).</summary>
    public decimal? ContainerChargesBase { get; init; }

    /// <summary>FOB + container charges per unit; final once the goods are received.</summary>
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

    /// <summary>(77) A linked order: 0 Saved, 1 Partially posted, 2 Posted; null for an invoice or a return.</summary>
    public int? InvoicingStatus { get; init; }

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

/// <summary>
/// "Shipped in containers" on a purchase invoice. SINCE SCRIPT 65 NO INVOICE MOVES STOCK WHEN IT IS POSTED, whatever its
/// mode: the goods enter with goods receipts (an invoice posted after the switch has UsesGoodsReceipts). The mode says
/// how: received with Receive goods... (1), or with the containers carrying them (2). Invoices posted before the switch
/// keep the old meaning: 1 took its stock when posted, 2 at the container offload.
/// </summary>
public static class PurchaseReceiptModes
{
    /// <summary>Not shipped in containers: received with Receive goods... (before script 65: stock in when posted).</summary>
    public const byte OnPosting = 1;

    /// <summary>Shipped in containers: received with the containers' goods receipts. Forced once a line is in a container.</summary>
    public const byte OnContainerOffload = 2;
}

/// <summary>The global settings (configuration.SettingDefinitions) the Purchase module reads.</summary>
public static class PurchaseSettingKeys
{
    /// <summary>
    /// Bool, default true (script 63): a new supplier invoice holds one item, and creating invoices from an order, its
    /// containers or an Excel file makes one invoice per item. Off: one invoice may hold several items. The creations
    /// can still choose for themselves (OnePerItem), and every invoice keeps the mode it was created with.
    /// </summary>
    public const string OneItemPerInvoice = "Purchase.OneItemPerInvoice";
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
    /// 1 = not shipped in containers, 2 = shipped in containers (see <see cref="PurchaseReceiptModes"/>). Chosen on an
    /// invoice since script 43 (<see cref="ShippedInContainers"/>); a line linked to a container forces 2.
    /// </summary>
    public byte ReceiptMode { get; init; } = PurchaseReceiptModes.OnPosting;

    /// <summary>An invoice whose goods travel in containers and are received with them (receipt mode 2).</summary>
    public bool ShippedInContainers => DocumentTypeCode == PurchaseDocumentTypes.Invoice && ReceiptMode == PurchaseReceiptModes.OnContainerOffload;

    /* (65) GOODS RECEIPTS. */

    /// <summary>
    /// A supplier invoice posted after goods receipts started: its posting moved no stock, its goods enter with goods
    /// receipts and their cost follows it. False on a draft (set when it is posted), on an invoice posted before (its
    /// stock entered when it was posted, or at its container's offload), on orders and returns.
    /// </summary>
    public bool UsesGoodsReceipts { get; init; }

    /// <summary>"Receive goods..." on this order or invoice is possible now (rules 14, 15). False on returns.</summary>
    public bool CanReceive { get; init; }

    /// <summary>
    /// Why "Receive goods..." is disabled, in the words of the procedures ("Approve the order first: goods are received
    /// against an approved order.", "Everything ordered is already received.", "Posted before goods receipts: its stock
    /// entered when it was posted (or when its container was offloaded)."...); null when it is not.
    /// </summary>
    public string? ReceiveBlockedReason { get; init; }

    /// <summary>When goods receipts started (the switch): "Posted before goods receipts ({date})". Null before the switch.</summary>
    public DateTime? GoodsReceiptsSinceUtc { get; init; }

    /// <summary>
    /// Supplier invoices: true = it holds ONE item (saving or posting a second one is refused, 65029; the page limits
    /// its item picker and offers Split by item), false = it may hold several items. Its own mode, chosen when it was
    /// created and kept (script 63), or the setting <see cref="PurchaseSettingKeys.OneItemPerInvoice"/> for an invoice
    /// created before. False on orders and returns, which are not concerned.
    /// </summary>
    public bool OneItemOnly { get; init; }

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

    /// <summary>
    /// Orders: 0 not, 1 partially, 2 fully invoiced (posted invoices); null on invoices and returns. Since script 77 it is
    /// what an approved order shows: Saved, Partially posted, Posted.
    /// </summary>
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

    /* (47) Supplier payments - posted purchase invoices only; null on orders, returns, drafts and cancelled ones. */

    /// <summary>What posted supplier payments have paid, in the invoice's currency.</summary>
    public decimal? PaidAmount { get; init; }

    /// <summary>Posted purchase returns made from it, in its currency: they lower what is owed.</summary>
    public decimal? ReturnedAmount { get; init; }

    /// <summary>Total less returns less payments, in the invoice's currency.</summary>
    public decimal? OutstandingAmount { get; init; }

    /// <summary>Unpaid, Partial or Paid.</summary>
    public string? PaymentStatus { get; init; }

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

    /// <summary>Posted documents (an approved order, whatever its invoices): the procedure has the other refusals.</summary>
    public bool CanCancel => Status == PurchaseDocumentStatus.Posted;

    /// <summary>
    /// Charges are typed on a DRAFT invoice; after posting they arrive as a landed cost adjustment
    /// instead. Never on an invoice from containers: an import's charges go on its containers (65020).
    /// </summary>
    public bool CanEditCharges
        => DocumentTypeCode == PurchaseDocumentTypes.Invoice && Status == PurchaseDocumentStatus.Draft && !IsContainerBound;

    /// <summary>
    /// A posted local invoice can receive charges that arrived late, through a landed cost adjustment (67012 on an import:
    /// since script 65 also on a "Shipped in containers" invoice whose lines are not linked yet).
    /// </summary>
    public bool CanAdjustLandedCost
        => DocumentTypeCode == PurchaseDocumentTypes.Invoice && Status == PurchaseDocumentStatus.Posted && !IsContainerBound
           && !ShippedInContainers;

    /// <summary>Shipped quantities are recorded on an approved order only — the procedure refuses anything else.</summary>
    public bool CanMarkShipped => DocumentTypeCode == PurchaseDocumentTypes.Order && Status == PurchaseDocumentStatus.Posted;

    /// <summary>
    /// An approved order with something left to invoice becomes a purchase invoice. Since script 43 an order with
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

    /// <summary>
    /// (65) The goods receipts of the document: an order's (made from it, its invoices or its containers), an invoice's
    /// (made from it, or whose pieces are matched to its lines). Oldest first.
    /// </summary>
    public IReadOnlyList<PurchaseDocumentGoodsReceiptDto> GoodsReceipts { get; init; } = [];

    /// <summary>
    /// (65) Supplier invoices: the cost adjustments of received goods this invoice caused - posted or cancelled - and its
    /// landed cost adjustments: the card "Cost of received goods". Empty for orders and returns.
    /// </summary>
    public IReadOnlyList<PurchaseDocumentCostAdjustmentDto> CostAdjustments { get; init; } = [];

    /// <summary>
    /// What the posting did - only on the answer to POST .../{id}/post (null on every read): the message, the cost of
    /// received goods adjusted, and the goods receipt of "Receive the goods now". Set after the document is read back.
    /// </summary>
    public PurchasePostResultDto? PostResult { get; set; }
}

/// <summary>A goods receipt of a purchase order or invoice (result set 9 of usp_PurchaseDocument_Get, script 65).</summary>
public sealed class PurchaseDocumentGoodsReceiptDto
{
    public int Id { get; init; }

    /// <summary>Null on a draft: "Assigned on posting".</summary>
    public string? DocumentNumber { get; init; }

    /// <summary>The date received.</summary>
    public DateTime DocumentDate { get; init; }

    /// <summary>1 Draft, 2 Posted, 3 Cancelled.</summary>
    public byte Status { get; init; }

    public string StatusName => GoodsReceiptStatus.Name(Status);

    /// <summary>Container, Order, Invoice or Manual.</summary>
    public string SourceKind { get; init; } = string.Empty;

    /// <summary>Created by a Delivery's completion.</summary>
    public bool IsAuto { get; init; }

    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public int? WarehouseId { get; init; }
    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }

    /// <summary>Every piece the receipt holds.</summary>
    public int ReceivedBase { get; init; }

    /// <summary>Its pieces that concern THIS document: on the order's lines, or matched to (or received from) the invoice's.</summary>
    public int HereBase { get; init; }

    /// <summary>The value at receipt, fixed when it is posted (0 on a draft).</summary>
    public decimal ValueAtReceiptBase { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }
}

/// <summary>
/// One cost adjustment of received goods (purchase.GoodsReceiptCostChanges, result set 10 of usp_PurchaseDocument_Get):
/// a goods receipt line brought to its new cost when this invoice (or its landed cost adjustment) was posted or
/// cancelled. Amount = to stock (changes the average cost) + to cost of sales (the part already sold).
/// </summary>
public sealed class PurchaseDocumentCostAdjustmentDto
{
    public int Id { get; init; }
    public DateTime ChangedAtUtc { get; init; }

    /// <summary>PINV, PINVCANCEL, LCA or LCACANCEL here (GRNPOST, GRNCANCEL, NEGSTOCK on the goods receipt).</summary>
    public string CauseKind { get; init; } = string.Empty;

    public int? CauseId { get; init; }
    public string? CauseNumber { get; init; }
    public int GoodsReceiptLineId { get; init; }
    public int GoodsReceiptId { get; init; }
    public string? GoodsReceiptNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>The pieces received on the line, and the share of them still in stock used for the split.</summary>
    public int ReceivedBase { get; init; }

    public decimal InStockBase { get; init; }
    public decimal? FobBefore { get; init; }
    public decimal? FobAfter { get; init; }
    public decimal? UnitCostBefore { get; init; }
    public decimal? UnitCostAfter { get; init; }
    public decimal AmountBase { get; init; }
    public decimal InventoryBase { get; init; }
    public decimal CogsBase { get; init; }
}

/// <summary>
/// What posting a purchase document did (script 65), beside the document itself: <see cref="Message"/> ("Posted:
/// PINV-BR-002-000011. Cost of received goods adjusted by +60.00 USD (stock 40.00, cost of sales 20.00). Goods received:
/// GRN-BR-002-000004."), the cost adjustment of goods already received, and the goods receipt of "Receive the goods
/// now". A receipt that failed leaves the invoice posted: <see cref="ReceiveWarning"/> says why.
/// </summary>
public sealed class PurchasePostResultDto
{
    public string? DocumentNumber { get; init; }
    public string Message { get; init; } = string.Empty;

    /// <summary>The cost of received goods brought to this invoice's price: amount = to stock + to cost of sales. 0 when nothing moved.</summary>
    public decimal CostAdjustedBase { get; init; }

    public decimal CostAdjustedInventoryBase { get; init; }
    public decimal CostAdjustedCogsBase { get; init; }

    /// <summary>The goods receipt lines whose cost moved.</summary>
    public int CostAdjustedLines { get; init; }

    public string? BaseCurrencyCode { get; init; }

    /// <summary>"Receive the goods now" was asked (a supplier invoice only).</summary>
    public bool ReceiveRequested { get; init; }

    /// <summary>The goods receipt created and posted with the invoice; null when not asked, or when it failed.</summary>
    public int? GoodsReceiptId { get; init; }

    public string? GoodsReceiptNumber { get; init; }

    /// <summary>"Invoice posted; the goods receipt was not: {reason}. Use Receive goods…" - null when nothing failed.</summary>
    public string? ReceiveWarning { get; init; }

    /// <summary>The same warning(s) as a list, for the pages that show warnings that way. Empty when nothing failed.</summary>
    public IReadOnlyList<string> Warnings { get; init; } = [];
}

/// <summary>
/// One line of a DRAFT supplier invoice, and what posting it would do to the cost of goods already received
/// (purchase.usp_PurchaseInvoice_ReceiptCostPreview, script 64). AN ESTIMATE: the posting re-matches everything.
/// </summary>
public sealed class ReceiptCostPreviewLineDto
{
    public int InvoiceLineId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int InvoicedBase { get; init; }

    /// <summary>The received pieces of its group not matched to an invoice yet, up to the line's pieces, first in first out.</summary>
    public int ReceivedNotInvoicedBase { get; init; }

    /// <summary>What those pieces cost now, per piece (landed); null when there are none.</summary>
    public decimal? CurrentCostBase { get; init; }

    /// <summary>What they would cost with this invoice, per piece; null when there are none.</summary>
    public decimal? InvoiceCostBase { get; init; }

    /// <summary>The cost adjustment: (invoice cost - current cost) x pieces.</summary>
    public decimal DifferenceBase { get; init; }

    /// <summary>The part of the difference that would go to the stock value, on today's company stock.</summary>
    public decimal EstimatedInventoryBase { get; init; }

    /// <summary>The part that would go to the cost of sales (pieces already sold).</summary>
    public decimal EstimatedCogsBase { get; init; }

    public int CompanyOnHandBase { get; init; }

    /// <summary>The goods receipts those pieces came from: "GRN-BR-002-000001, GRN-BR-002-000003".</summary>
    public string? Receipts { get; init; }

    public bool IsEstimate { get; init; } = true;
}

/// <summary>
/// The post confirmation's preview of a DRAFT supplier invoice (GET api/purchase/documents/{id}/receipt-cost-preview):
/// the totals of its lines and the sentence the confirmation shows - "{n} pcs already received will have their cost
/// adjusted by +60.00 USD (estimate: stock 40.00, cost of sales 20.00)." or "No goods received yet: their cost will be
/// this invoice's when they arrive." A document that is not a draft has no lines.
/// </summary>
public sealed class ReceiptCostPreviewDto
{
    public int InvoiceId { get; init; }
    public string? DocumentNumber { get; init; }

    /// <summary>Draft, Posted or Cancelled: only a draft is previewed.</summary>
    public string Status { get; init; } = PurchaseDocumentStatus.Draft;

    public string? BaseCurrencyCode { get; init; }

    /// <summary>Received pieces whose cost the posting would adjust.</summary>
    public int ReceivedNotInvoicedBase { get; init; }

    public decimal DifferenceBase { get; init; }
    public decimal EstimatedInventoryBase { get; init; }
    public decimal EstimatedCogsBase { get; init; }

    /// <summary>Some goods of the invoice's lines are already received and not invoiced: the posting adjusts their cost.</summary>
    public bool HasReceivedGoods => ReceivedNotInvoicedBase > 0;

    public bool IsEstimate => true;
    public string? Message { get; init; }
    public IReadOnlyList<ReceiptCostPreviewLineDto> Lines { get; init; } = [];
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

    /// <summary>
    /// A NEW supplier invoice: true = it holds one item (65029 refuses a second), false = it may hold several; null =
    /// the setting <see cref="PurchaseSettingKeys.OneItemPerInvoice"/>. Ignored on an update (an invoice keeps the mode
    /// it was created with) and on orders and returns.
    /// </summary>
    public bool? OneItemOnly { get; init; }

    public IReadOnlyList<SavePurchaseDocumentLineRequest> Lines { get; init; } = [];

    public string? RowVersion { get; init; }
}

public sealed class PostPurchaseDocumentRequest
{
    public string? RowVersion { get; init; }

    /// <summary>
    /// (65, decision 7) "Receive the goods now", a supplier invoice only (ignored for orders and returns): once the invoice
    /// is posted, its lines not in a container are received with one goods receipt, created and posted in a second
    /// transaction. Needs purchase.goodsreceipts.create and .post besides the invoice's post (403 otherwise, nothing
    /// posted). A receipt that fails leaves the invoice posted: the answer's postResult.receiveWarning says why.
    /// </summary>
    public bool ReceiveNow { get; init; }
}

public sealed class CancelPurchaseDocumentRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

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
/// Draft purchase invoices from container lines of one order — ONE PER ITEM (script 45), or one invoice holding
/// every item (<see cref="OnePerItem"/> false, script 63). NO LINES = everything loaded and not yet invoiced.
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

    /// <summary>
    /// True = one invoice per item, each holding one item; false = ONE invoice holding every selected line, which may
    /// hold several items; null = the setting <see cref="PurchaseSettingKeys.OneItemPerInvoice"/>.
    /// </summary>
    public bool? OnePerItem { get; init; }
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

    /// <summary>
    /// Order → invoices: true = one invoice per item, each holding one item; false = ONE invoice holding everything
    /// that remains, which may hold several items; null = the setting <see cref="PurchaseSettingKeys.OneItemPerInvoice"/>.
    /// Ignored for a return.
    /// </summary>
    public bool? OnePerItem { get; init; }
}

/// <summary>
/// One supplier invoice a create or a split made: one per item (script 45), or one holding every item when the
/// creation asked for it (script 63). The item is the one of its first line.
/// </summary>
public sealed class CreatedPurchaseInvoiceDto
{
    public int Id { get; init; }
    public int? ItemId { get; init; }
    public string? ItemCode { get; init; }
    public string? ItemName { get; init; }

    /// <summary>How many items it holds: 1, or more for one invoice holding every item (script 63).</summary>
    public int ItemCount { get; init; }

    public int LineCount { get; init; }
    public int QuantityBase { get; init; }
    public decimal TotalAmount { get; init; }
}

/// <summary>
/// The answer to "create invoice" from an order or from its containers: one draft per item of the selection, or one
/// draft holding every item (script 63). <see cref="Id"/> is <see cref="FirstId"/> under the name the pages read before
/// invoices were split by item.
/// </summary>
public sealed class CreatedPurchaseInvoicesDto
{
    public int FirstId { get; init; }

    /// <summary>= <see cref="FirstId"/>: the field the pages opened the new draft with.</summary>
    public int Id => FirstId;

    public IReadOnlyList<CreatedPurchaseInvoiceDto> Invoices { get; init; } = [];

    /// <summary>"3 invoices created, one per item", "Invoice created with 3 items" or "Invoice created".</summary>
    public string Message { get; init; } = string.Empty;

    public static CreatedPurchaseInvoicesDto From(IReadOnlyList<CreatedPurchaseInvoiceDto> invoices) => new()
    {
        FirstId = invoices.Count > 0 ? invoices[0].Id : 0,
        Invoices = invoices,
        Message = invoices.Count switch
        {
            1 when invoices[0].ItemCount > 1 => $"Invoice created with {invoices[0].ItemCount} items",
            1 => "Invoice created",
            _ => $"{invoices.Count} invoices created, one per item",
        },
    };
}

/// <summary>
/// Split a draft supplier invoice holding several items into one invoice per item: one made before script 45, or one
/// that may hold several (script 63). Every invoice it leaves holds one item from then on.
/// </summary>
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

    /// <summary>Draft, PendingApproval, Posted, Cancelled or the code 1–5.</summary>
    public string? Status { get; init; }

    /// <summary>
    /// (77) Orders: 0 Saved, 1 Partially posted, 2 Posted - with <see cref="Status"/> Posted, the stage the order list
    /// filters on. Ignored on invoices and returns.
    /// </summary>
    public int? InvoicingStatus { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    /// <summary>(65) Orders: approved with goods still to come ("To receive").</summary>
    public bool? ToReceive { get; init; }

    /// <summary>(65) Supplier invoices: posted and not every piece received ("Not fully received").</summary>
    public bool? NotFullyReceived { get; init; }

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

    /// <summary>
    /// Supplier invoices: true = one invoice per item of the file, each holding one item; false = one invoice holding
    /// every item; null = the setting <see cref="PurchaseSettingKeys.OneItemPerInvoice"/>. Ignored for orders and returns.
    /// </summary>
    public bool? OnePerItem { get; init; }
}
