using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/* Supplier payments (US-PAY-001, scripts 46-47): money going OUT to a supplier or service provider, in
   one or more payment lines (methods, currencies, accounts), optionally allocated to purchase invoices OR
   to container charges. The payment's own currency is the control currency: the lines and the
   allocations balance against its amount in that currency. */

/// <summary>Draft, Posted or Reversed. A posted payment is never deleted: it is reversed, and both are kept.</summary>
public static class SupplierPaymentStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;
    public const byte ReversedCode = 3;

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Reversed = "Reversed";

    public static string ToName(byte code) => code switch
    {
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
/// What the payment is FOR. A Free Payment is an advance to the payee, allocated later; a Purchase
/// Invoice Payment pays purchase invoices; a Container Charge Payment pays container charges. The last
/// two must allocate exactly their own amount, and never mix the two kinds.
/// </summary>
public static class SupplierPaymentTypes
{
    public const byte FreePayment = 1;
    public const byte PurchaseInvoicePayment = 2;
    public const byte ContainerChargePayment = 3;

    public static string ToName(byte code) => code switch
    {
        PurchaseInvoicePayment => "Purchase Invoice Payment",
        ContainerChargePayment => "Container Charge Payment",
        _ => "Free Payment",
    };
}

/// <summary>The kind of document an allocation pays: PINV (purchase invoice) or CHARGE (container charge).</summary>
public static class PaymentDocumentKinds
{
    public const string PurchaseInvoice = "PINV";
    public const string ContainerCharge = "CHARGE";
}

/// <summary>A cheque line's state at the bank. Only this changes on a posted payment.</summary>
public static class ChequeClearanceStatus
{
    public const byte Pending = 1;
    public const byte Cleared = 2;
    public const byte Returned = 3;
}

/* ── reading ───────────────────────────────────────────────────────────────────────────────── */

/// <summary>One row of the payments list.</summary>
public sealed class PaymentListDto
{
    public int Id { get; init; }
    public string? PaymentNumber { get; init; }
    public DateTime PaymentDate { get; init; }
    public int PayeeId { get; init; }
    public string PayeeCode { get; init; } = string.Empty;
    public string PayeeName { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;

    /// <summary>1 Free, 2 Purchase Invoice, 3 Container Charge.</summary>
    public byte PaymentType { get; init; }

    public string PaymentTypeName => SupplierPaymentTypes.ToName(PaymentType);
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }

    /// <summary>In the payment currency.</summary>
    public decimal Amount { get; init; }

    /// <summary>Units of the payment currency per 1 base currency.</summary>
    public decimal ExchangeRate { get; init; }

    public decimal AmountBase { get; init; }
    public string? Reference { get; init; }
    public string Status { get; init; } = SupplierPaymentStatus.Draft;

    /// <summary>The payment methods its lines use, e.g. "Bank Transfer, Cash".</summary>
    public string? Methods { get; init; }

    /// <summary>What live allocations have used, in the payment currency.</summary>
    public decimal AllocatedAmount { get; init; }

    /// <summary>The advance still to allocate (a posted Free Payment only), in the payment currency.</summary>
    public decimal UnappliedAmount { get; init; }

    public int DocumentCount { get; init; }
    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? ReversedAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>One payment line: how much went out, in what currency, by what method, from which account.</summary>
public sealed class PaymentLineDto
{
    public int Id { get; init; }
    public int LineNo { get; init; }
    public int PaymentMethodId { get; init; }
    public string MethodCode { get; init; } = string.Empty;
    public string MethodName { get; init; } = string.Empty;

    /// <summary>A cheque line (method code CHQ): it carries the cheque fields and a clearance status.</summary>
    public bool IsCheque { get; init; }

    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }

    /// <summary>In the line currency.</summary>
    public decimal Amount { get; init; }

    /// <summary>The multiplier from the line currency to the payment currency (1 when they are the same).</summary>
    public decimal RateToPayment { get; init; }

    /// <summary>Amount x RateToPayment: what the line counts for in the payment's balance.</summary>
    public decimal AmountPaymentCurrency { get; init; }

    public decimal AmountBase { get; init; }
    public int CashBankAccountId { get; init; }
    public string AccountCode { get; init; } = string.Empty;
    public string AccountName { get; init; } = string.Empty;
    public string? Reference { get; init; }
    public string? ChequeNo { get; init; }
    public DateTime? ChequeDate { get; init; }
    public DateTime? ChequeDueDate { get; init; }

    /// <summary>Cheque lines: 1 Pending, 2 Cleared, 3 Returned. Null on other lines.</summary>
    public byte? ClearanceStatus { get; init; }

    public string? ClearanceStatusName { get; init; }
    public DateTime? ClearanceUpdatedAtUtc { get; init; }
    public string? ClearanceUpdatedByName { get; init; }
}

/// <summary>
/// A purchase invoice or container charge the payment pays. The amount is in the DOCUMENT's currency;
/// RateToPayment converts it to the payment currency, and its base value uses the document's own stored
/// rate. A removed allocation stays in the list with its removal stamped: it is proof it happened.
/// </summary>
public sealed class PaymentAllocationDto
{
    public int Id { get; init; }

    /// <summary>PINV or CHARGE.</summary>
    public string DocumentKind { get; init; } = string.Empty;

    public int DocumentId { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }

    /// <summary>The container(s) the document concerns; derived, never typed.</summary>
    public string? ContainerRef { get; init; }

    /// <summary>Container charges only: Freight, Customs, BIVAC...</summary>
    public string? ChargeTypeName { get; init; }

    public string? DocumentReference { get; init; }
    public int DocumentCurrencyId { get; init; }
    public string DocumentCurrencyCode { get; init; } = string.Empty;
    public int DocumentDecimalPlaces { get; init; }
    public decimal DocumentTotal { get; init; }

    /// <summary>Purchase invoices: posted returns made from it, in its currency.</summary>
    public decimal ReturnedAmount { get; init; }

    /// <summary>What OTHER posted payments have paid it, in its currency.</summary>
    public decimal PreviouslyPaid { get; init; }

    public decimal? OutstandingAmount { get; init; }
    public string? PaymentStatus { get; init; }
    public decimal AmountDocCurrency { get; init; }
    public decimal DocExchangeRate { get; init; }
    public decimal RateToPayment { get; init; }
    public decimal AmountPaymentCurrency { get; init; }
    public decimal AmountBase { get; init; }
    public DateTime AllocatedAtUtc { get; init; }
    public string? AllocatedByName { get; init; }
    public DateTime? RemovedAtUtc { get; init; }
    public string? RemovedByName { get; init; }

    /// <summary>True while the allocation still counts toward what the document has been paid.</summary>
    public bool IsLive => RemovedAtUtc is null;
}

public sealed class PaymentFileDto
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

public sealed class PaymentFileContent
{
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}

public sealed class PaymentAuditDto
{
    public long Id { get; init; }
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>A payment, whole: header, payment lines, allocations, files and audit.</summary>
public sealed class PaymentDto
{
    public int Id { get; init; }
    public string? PaymentNumber { get; init; }
    public DateTime PaymentDate { get; init; }
    public int PayeeId { get; init; }
    public string PayeeCode { get; init; } = string.Empty;
    public string PayeeName { get; init; } = string.Empty;
    public string? PayeeAddress { get; init; }
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;

    /// <summary>1 Free, 2 Purchase Invoice, 3 Container Charge.</summary>
    public byte PaymentType { get; init; }

    public string PaymentTypeName => SupplierPaymentTypes.ToName(PaymentType);
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public int DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }

    /// <summary>In the payment currency: the control total the lines (and allocations) must equal.</summary>
    public decimal Amount { get; init; }

    /// <summary>Units of the payment currency per 1 base currency ("Exchange Rate to USD"). 1 for the base currency.</summary>
    public decimal ExchangeRate { get; init; }

    /// <summary>Amount in the base currency ("Amount in USD").</summary>
    public decimal AmountBase { get; init; }

    public string? BaseCurrencyCode { get; init; }
    public string? Reference { get; init; }
    public string? Notes { get; init; }
    public string Status { get; init; } = SupplierPaymentStatus.Draft;

    /// <summary>What the payment lines add up to in the payment currency. Must equal <see cref="Amount"/> to post.</summary>
    public decimal LinesTotal { get; init; }

    /// <summary>What live allocations add up to in the payment currency. Must equal <see cref="Amount"/> on an invoice / charge payment.</summary>
    public decimal AllocatedTotal { get; init; }

    /// <summary>The advance still to allocate, in the payment currency. Only a posted Free Payment has any.</summary>
    public decimal UnappliedAmount { get; init; }

    /// <summary>PINV or CHARGE once anything is allocated (a Free Payment's later allocations decide it); null otherwise.</summary>
    public string? AllocationKind { get; init; }

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

    public IReadOnlyList<PaymentLineDto> Lines { get; init; } = [];
    public IReadOnlyList<PaymentAllocationDto> Allocations { get; init; } = [];
    public IReadOnlyList<PaymentFileDto> Files { get; init; } = [];
    public IReadOnlyList<PaymentAuditDto> Audit { get; init; } = [];
}

/// <summary>
/// A document the allocation table offers: a posted purchase invoice or container charge of the payee
/// with something left to pay. Amounts are in the document's currency; DefaultRateToPayment (when the
/// payment's currency was given) is the multiplier the row pre-fills.
/// </summary>
public sealed class OpenPayableDocumentDto
{
    public string DocumentKind { get; init; } = string.Empty;
    public int DocumentId { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }
    public string? ContainerRef { get; init; }
    public string? ChargeTypeName { get; init; }
    public string? DocumentReference { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }
    public decimal ExchangeRate { get; init; }
    public decimal DocumentTotal { get; init; }
    public decimal ReturnedAmount { get; init; }
    public decimal PreviouslyPaid { get; init; }
    public decimal OutstandingAmount { get; init; }

    /// <summary>Unpaid or Partial.</summary>
    public string PaymentStatus { get; init; } = string.Empty;

    public decimal OutstandingBase { get; init; }
    public decimal? DefaultRateToPayment { get; init; }
}

/// <summary>
/// The multiplier a line or allocation pre-fills, from one currency to the payment currency on a date.
/// RateToPayment is null when either currency has no official rate: a warning on the page, not an error.
/// </summary>
public sealed class PaymentRateDto
{
    public int FromCurrencyId { get; init; }
    public int PaymentCurrencyId { get; init; }
    public decimal? PaymentRate { get; init; }
    public decimal? FromRate { get; init; }
    public decimal? RateToPayment { get; init; }
}

public sealed class PaymentQuery
{
    public string? Search { get; init; }
    public int? PayeeId { get; init; }
    public int? BranchId { get; init; }

    /// <summary>Draft | Posted | Reversed, or null for all.</summary>
    public string? Status { get; init; }

    /// <summary>1 Free | 2 Purchase Invoice | 3 Container Charge, or null for all.</summary>
    [Range(1, 3)]
    public int? PaymentType { get; init; }

    public int? CurrencyId { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    /// <summary>PaymentNumber, PaymentDate, PayeeName, Status, AmountBase or CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "PaymentDate";

    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

/* ── writing ───────────────────────────────────────────────────────────────────────────────── */

public sealed class SavePaymentLineRequest
{
    [Range(1, int.MaxValue)]
    public int PaymentMethodId { get; init; }

    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }

    /// <summary>Multiplier to the payment currency. Null = from the official rates (1 for the payment's own currency).</summary>
    [Range(0.000000000001, 999999999999.0)]
    public decimal? RateToPayment { get; init; }

    [Range(1, int.MaxValue)]
    public int CashBankAccountId { get; init; }

    [StringLength(100)]
    public string? Reference { get; init; }

    /// <summary>Cheque lines (method CHQ): required. Ignored on other lines.</summary>
    [StringLength(50)]
    public string? ChequeNo { get; init; }

    public DateOnly? ChequeDate { get; init; }
    public DateOnly? ChequeDueDate { get; init; }
}

public sealed class SavePaymentAllocationRequest
{
    /// <summary>PINV or CHARGE.</summary>
    [Required]
    [RegularExpression("^(PINV|CHARGE)$", ErrorMessage = "Document kind must be PINV or CHARGE.")]
    public string DocumentKind { get; init; } = PaymentDocumentKinds.PurchaseInvoice;

    [Range(1, int.MaxValue)]
    public int DocumentId { get; init; }

    /// <summary>In the DOCUMENT's currency, not the payment's.</summary>
    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }

    /// <summary>Multiplier to the payment currency. Null = from the official rates.</summary>
    [Range(0.000000000001, 999999999999.0)]
    public decimal? RateToPayment { get; init; }
}

public sealed class SavePaymentRequest
{
    [Required]
    public DateOnly PaymentDate { get; init; }

    [Range(1, int.MaxValue)]
    public int PayeeId { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>1 Free Payment (default), 2 Purchase Invoice Payment, 3 Container Charge Payment.</summary>
    [Range(1, 3)]
    public byte PaymentType { get; init; } = SupplierPaymentTypes.FreePayment;

    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    /// <summary>In the payment currency. The control total: the lines (and allocations) must add up to it before posting.</summary>
    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }

    /// <summary>Units of the payment currency per 1 base currency. Null = the official rate on the payment date.</summary>
    [Range(0.000001, 999999999999.999999)]
    public decimal? ExchangeRate { get; init; }

    [StringLength(100)]
    public string? Reference { get; init; }

    [StringLength(500)]
    public string? Notes { get; init; }

    public IReadOnlyList<SavePaymentLineRequest> Lines { get; init; } = [];

    /// <summary>Only on an invoice or charge payment, and only of its own kind; a Free Payment sends none.</summary>
    public IReadOnlyList<SavePaymentAllocationRequest> Allocations { get; init; } = [];

    /// <summary>Required on update to detect concurrent edits.</summary>
    public string? RowVersion { get; init; }
}

public sealed class PostPaymentRequest
{
    public string? RowVersion { get; init; }
}

public sealed class ReversePaymentRequest
{
    [Required]
    [StringLength(500, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

/// <summary>Allocate the unapplied advance of a posted Free Payment to invoices OR charges.</summary>
public sealed class AllocatePaymentRequest
{
    [MinLength(1)]
    public IReadOnlyList<SavePaymentAllocationRequest> Allocations { get; init; } = [];

    public string? RowVersion { get; init; }
}

public sealed class SetChequeStatusRequest
{
    /// <summary>1 Pending, 2 Cleared, 3 Returned.</summary>
    [Range(1, 3)]
    public byte ClearanceStatus { get; init; }
}
