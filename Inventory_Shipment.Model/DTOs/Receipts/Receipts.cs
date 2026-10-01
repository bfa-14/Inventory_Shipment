using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Receipts;

/// <summary>Draft, Posted or Reversed. A posted receipt is never deleted: it is reversed, and both are kept.</summary>
public static class ReceiptStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;
    public const byte ReversedCode = 3;

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Reversed = "Reversed";

    public static string ToName(byte code) => code switch
    {
        DraftCode => Draft,
        PostedCode => Posted,
        ReversedCode => Reversed,
        _ => Draft,
    };

    public static byte? ToCode(string? name) => name?.Trim().ToLowerInvariant() switch
    {
        "draft" => DraftCode,
        "posted" => PostedCode,
        "reversed" => ReversedCode,
        _ => null,
    };
}

/// <summary>
/// What the receipt is FOR. A Free Receipt is money received with no invoice in mind: it becomes
/// unapplied credit that can be allocated later. A Sales Allocation receipt names the invoices it
/// pays, and must pay exactly its own amount.
/// </summary>
public static class ReceiptPaymentTypes
{
    public const byte FreeReceipt = 1;
    public const byte SalesAllocation = 2;

    public const string FreeReceiptName = "Free Receipt";
    public const string SalesAllocationName = "Sales Allocation";

    public static string ToName(byte code) => code == SalesAllocation ? SalesAllocationName : FreeReceiptName;
}

/* ── reading ───────────────────────────────────────────────────────────────────────────────── */

/// <summary>One row of the receipts list.</summary>
public sealed class ReceiptListDto
{
    public int Id { get; init; }
    public string? ReceiptNumber { get; init; }
    public DateTime ReceiptDate { get; init; }
    public int ClientId { get; init; }
    public string ClientCode { get; init; } = string.Empty;
    public string ClientName { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;

    /// <summary>1 Free Receipt, 2 Sales Allocation.</summary>
    public byte PaymentType { get; init; }

    public string PaymentTypeName => ReceiptPaymentTypes.ToName(PaymentType);
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }

    /// <summary>In the header currency.</summary>
    public decimal Amount { get; init; }

    /// <summary>Units of the currency per 1 base currency.</summary>
    public decimal ExchangeRate { get; init; }

    /// <summary>The header amount in the base currency.</summary>
    public decimal AmountBase { get; init; }

    public string Status { get; init; } = ReceiptStatus.Draft;

    /// <summary>The invoice that created this receipt automatically (a Cash sale); null for an ordinary receipt.</summary>
    public int? SourceSalesDocumentId { get; init; }

    public string? SourceInvoiceNumber { get; init; }

    /// <summary>What live allocations have used, in the base currency.</summary>
    public decimal AllocatedBase { get; init; }

    /// <summary>Credit still to allocate (a posted Free Receipt only), in the base currency.</summary>
    public decimal UnappliedBase { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? ReversedAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>One payment line: how much came in, in what currency, by what method, into which account.</summary>
public sealed class ReceiptLineDto
{
    public int Id { get; init; }
    public int LineNo { get; init; }
    public int PaymentMethodId { get; init; }
    public string MethodCode { get; init; } = string.Empty;
    public string MethodName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }
    public decimal Amount { get; init; }
    public decimal ExchangeRate { get; init; }
    public decimal AmountBase { get; init; }
    public int CashBankAccountId { get; init; }
    public string AccountCode { get; init; } = string.Empty;
    public string AccountName { get; init; } = string.Empty;
    public string? Reference { get; init; }
}

/// <summary>
/// An invoice the receipt pays. The amount is in the INVOICE's currency; its base value is that
/// amount divided by the invoice's own rate, snapshotted when the allocation was made, so it never
/// moves. A removed allocation stays in the list with its removal stamped: it is proof it happened.
/// </summary>
public sealed class ReceiptAllocationDto
{
    public int Id { get; init; }
    public int SalesDocumentId { get; init; }
    public string InvoiceNumber { get; init; } = string.Empty;
    public DateTime InvoiceDate { get; init; }
    public int InvoiceCurrencyId { get; init; }
    public string InvoiceCurrencyCode { get; init; } = string.Empty;
    public int InvoiceDecimalPlaces { get; init; }
    public decimal InvoiceTotal { get; init; }
    public decimal AmountInvoiceCurrency { get; init; }
    public decimal InvoiceExchangeRate { get; init; }
    public decimal AmountBase { get; init; }
    public DateTime AllocatedAtUtc { get; init; }
    public string? AllocatedByName { get; init; }
    public DateTime? RemovedAtUtc { get; init; }
    public string? RemovedByName { get; init; }

    /// <summary>True while the allocation still counts toward what the invoice has been paid.</summary>
    public bool IsLive => RemovedAtUtc is null;
}

public sealed class ReceiptFileDto
{
    public int Id { get; init; }
    public int? AttachmentTypeId { get; init; }

    /// <summary>The Type column of the attachments grid.</summary>
    public string? Category { get; init; }

    /// <summary>The Sub Type column.</summary>
    public string? SubType { get; init; }

    public string? Note { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class ReceiptFileContent
{
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}

public sealed class ReceiptAuditDto
{
    public long Id { get; init; }
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>A receipt, whole: header, payment lines, allocations, files and audit.</summary>
public sealed class ReceiptDto
{
    public int Id { get; init; }
    public string? ReceiptNumber { get; init; }
    public DateTime ReceiptDate { get; init; }
    public int ClientId { get; init; }
    public string ClientCode { get; init; } = string.Empty;
    public string ClientName { get; init; } = string.Empty;
    public string? ClientAddress { get; init; }
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;

    /// <summary>1 Free Receipt, 2 Sales Allocation.</summary>
    public byte PaymentType { get; init; }

    public string PaymentTypeName => ReceiptPaymentTypes.ToName(PaymentType);
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public int DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }

    /// <summary>In the header currency.</summary>
    public decimal Amount { get; init; }

    /// <summary>Units of the header currency per 1 base currency. Exactly 1 on a base-currency receipt.</summary>
    public decimal ExchangeRate { get; init; }

    /// <summary>The header amount in the base currency: what the payment lines and allocations balance against.</summary>
    public decimal AmountBase { get; init; }

    public string? BaseCurrencyCode { get; init; }
    public string? Notes { get; init; }
    public string Status { get; init; } = ReceiptStatus.Draft;

    /// <summary>
    /// The invoice that created this receipt automatically (a Cash sale). Such a receipt cannot be
    /// reversed on its own; cancelling that invoice reverses it.
    /// </summary>
    public int? SourceSalesDocumentId { get; init; }

    public string? SourceInvoiceNumber { get; init; }

    /// <summary>What the payment lines add up to, in the base currency. Must equal <see cref="AmountBase"/> to post.</summary>
    public decimal LinesBase { get; init; }

    /// <summary>What live allocations add up to, in the base currency. Must equal <see cref="AmountBase"/> on a Sales Allocation receipt.</summary>
    public decimal AllocatedBase { get; init; }

    /// <summary>Credit still to allocate, in the base currency. Only a posted Free Receipt has any.</summary>
    public decimal UnappliedBase { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public int? PostedBy { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? ReversedAtUtc { get; init; }
    public int? ReversedBy { get; init; }
    public string? ReversedByName { get; init; }
    public string? ReverseReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public int? UpdatedBy { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    public IReadOnlyList<ReceiptLineDto> Lines { get; init; } = [];
    public IReadOnlyList<ReceiptAllocationDto> Allocations { get; init; } = [];
    public IReadOnlyList<ReceiptFileDto> Files { get; init; } = [];
    public IReadOnlyList<ReceiptAuditDto> Audit { get; init; } = [];
}

/// <summary>
/// An invoice the allocation panel offers: a posted sales invoice of the customer with something left
/// to pay. Outstanding is in the invoice's currency; <see cref="OutstandingBase"/> is what it is worth
/// in the base currency at the invoice's own rate.
/// </summary>
public sealed class OpenInvoiceDto
{
    public int Id { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }
    public DateTime? DueDate { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }
    public decimal ExchangeRate { get; init; }
    public decimal InvoiceTotal { get; init; }
    public decimal PaidAmount { get; init; }
    public decimal OutstandingAmount { get; init; }

    /// <summary>Unpaid or Partial.</summary>
    public string PaymentStatus { get; init; } = string.Empty;

    public decimal OutstandingBase { get; init; }
}

/// <summary>
/// The rate a payment line pre-fills: the official rate on a date, 1 for the base currency. Rate is
/// null when none is defined, which the page turns into a warning and an editable box, not an error.
/// </summary>
public sealed class ReceiptRateDto
{
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? Symbol { get; init; }
    public int DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }
    public decimal? Rate { get; init; }
    public DateTime? RateDate { get; init; }
    public string? BaseCurrencyCode { get; init; }
}

public sealed class ReceiptQuery
{
    public string? Search { get; init; }
    public int? ClientId { get; init; }
    public int? BranchId { get; init; }

    /// <summary>Draft | Posted | Reversed, or null for all.</summary>
    public string? Status { get; init; }

    /// <summary>1 Free Receipt | 2 Sales Allocation, or null for both.</summary>
    [Range(1, 2)]
    public int? PaymentType { get; init; }

    public int? CurrencyId { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    /// <summary>ReceiptNumber, ReceiptDate, ClientName, Status, AmountBase or CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "ReceiptDate";

    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

/* ── writing ───────────────────────────────────────────────────────────────────────────────── */

public sealed class SaveReceiptLineRequest
{
    [Range(1, int.MaxValue)]
    public int PaymentMethodId { get; init; }

    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }

    /// <summary>Units of the line's currency per 1 base currency. Null = the official rate on the receipt date (1 for the base currency).</summary>
    [Range(0.000001, 999999999999.999999)]
    public decimal? ExchangeRate { get; init; }

    [Range(1, int.MaxValue)]
    public int CashBankAccountId { get; init; }

    [StringLength(100)]
    public string? Reference { get; init; }
}

public sealed class SaveReceiptAllocationRequest
{
    [Range(1, int.MaxValue)]
    public int SalesDocumentId { get; init; }

    /// <summary>In the INVOICE's currency, not the receipt's.</summary>
    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }
}

public sealed class SaveReceiptRequest
{
    [Required]
    public DateOnly ReceiptDate { get; init; }

    [Range(1, int.MaxValue)]
    public int ClientId { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>1 Free Receipt (default), 2 Sales Allocation.</summary>
    [Range(1, 2)]
    public byte PaymentType { get; init; } = ReceiptPaymentTypes.FreeReceipt;

    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    /// <summary>In the header currency. A control total: the payment lines must add up to it before it can be posted.</summary>
    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }

    /// <summary>Units of the header currency per 1 base currency. Null = the official rate on the receipt date.</summary>
    [Range(0.000001, 999999999999.999999)]
    public decimal? ExchangeRate { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<SaveReceiptLineRequest> Lines { get; init; } = [];

    /// <summary>Only on a Sales Allocation receipt; a Free Receipt must send none.</summary>
    public IReadOnlyList<SaveReceiptAllocationRequest> Allocations { get; init; } = [];

    /// <summary>Required on update to detect concurrent edits.</summary>
    public string? RowVersion { get; init; }
}

public sealed class PostReceiptRequest
{
    public string? RowVersion { get; init; }
}

public sealed class ReverseReceiptRequest
{
    [Required]
    [StringLength(500, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

/// <summary>Allocate the unapplied credit of a posted Free Receipt to invoices.</summary>
public sealed class AllocateReceiptRequest
{
    [MinLength(1)]
    public IReadOnlyList<SaveReceiptAllocationRequest> Allocations { get; init; } = [];

    public string? RowVersion { get; init; }
}
