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

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Cancelled = "Cancelled";
    public const string Closed = "Closed";

    public static string From(byte code) => code switch
    {
        PostedCode => Posted,
        CancelledCode => Cancelled,
        ClosedCode => Closed,
        _ => Draft,
    };

    public static byte? ToCode(string? status) => status switch
    {
        "1" or Draft => DraftCode,
        "2" or Posted => PostedCode,
        "3" or Cancelled => CancelledCode,
        "4" or Closed => ClosedCode,
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

    /// <summary>The cost per base unit in the base currency, written by the posting.</summary>
    public decimal? UnitCostBase { get; init; }

    public decimal ReceivedQuantityBase { get; init; }
    public decimal ReturnedQuantityBase { get; init; }

    /// <summary>Orders: still to receive; invoices: still returnable; returns: null.</summary>
    public decimal? RemainingBase { get; init; }

    public int? ImportRowNumber { get; init; }
    public string? Notes { get; init; }
    public int? SourceLineId { get; init; }
    public decimal OnHandBase { get; init; }
    public decimal? ItemLastCost { get; init; }
    public decimal? ItemAverageCost { get; init; }
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
    public string? Notes { get; init; }
    public string Status { get; init; } = PurchaseDocumentStatus.Draft;
    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }
    public int? SourceDocumentId { get; init; }
    public string? SourceDocumentNumber { get; init; }
    public string? SourceDocumentTypeCode { get; init; }
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

    /// <summary>An open order with something left to receive becomes a purchase invoice.</summary>
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
    public IReadOnlyList<PurchaseDocumentFileDto> Files { get; init; } = [];
    public IReadOnlyList<PurchaseDocumentAuditDto> Audit { get; init; } = [];
    public IReadOnlyList<LinkedPurchaseDocumentDto> Linked { get; init; } = [];
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

    /// <summary>Ignored by the engine: one document = one warehouse, the header's. Accepted so a page can send what it shows.</summary>
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

    [Range(1, int.MaxValue)]
    public int WarehouseId { get; init; }

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

/// <summary>Make the next document of the chain (order → invoice, invoice → return) from a posted one.</summary>
public sealed class CreateFromSourceRequest
{
    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }
}

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
