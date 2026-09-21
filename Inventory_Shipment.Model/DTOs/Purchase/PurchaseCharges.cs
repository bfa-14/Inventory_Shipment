using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/// <summary>Which document a charge was entered on: the invoice itself, or a later landed cost adjustment.</summary>
public static class ChargeDocumentKinds
{
    public const string Invoice = "PINV";
    public const string Adjustment = "LCA";
}

/// <summary>
/// One charge on a purchase invoice or on a landed cost adjustment.
///
/// THE AMOUNT IS IN THE CHARGE'S OWN CURRENCY, converted once at the document-date rate: a freight
/// bill in EUR on a USD invoice is entered as it was received and stored in both. What reaches the
/// goods is <see cref="AllocatedBase"/>, and it is null until the document is posted — allocation
/// is the posting's work, not the typing's.
/// </summary>
public sealed class PurchaseChargeDto
{
    public int Id { get; init; }

    /// <summary>PINV (entered on the invoice) or LCA (on an adjustment) — see <see cref="ChargeDocumentKinds"/>.</summary>
    public string DocumentKind { get; init; } = ChargeDocumentKinds.Invoice;

    public int DocumentId { get; init; }

    /// <summary>The number of the document the charge belongs to: the invoice's, or the adjustment's.</summary>
    public string? SourceNumber { get; init; }

    /// <summary>1-based within its document. The "Charge N:" of the server's refusals.</summary>
    public int LineNumber { get; init; }

    public int ChargeTypeId { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;
    public string? Description { get; init; }

    /// <summary>Who billed it — the forwarder, the clearing agent. Optional: not every charge has an invoice of its own.</summary>
    public int? ProviderPartyId { get; init; }

    public string? ProviderName { get; init; }

    /// <summary>The provider's invoice or receipt number.</summary>
    public string? Reference { get; init; }

    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public byte RateType { get; init; }
    public decimal ExchangeRate { get; init; }

    /// <summary>In the charge's currency, as it was billed.</summary>
    public decimal Amount { get; init; }

    /// <summary>The same amount in the base currency, at the document-date rate.</summary>
    public decimal AmountBase { get; init; }

    public string AllocationMethod { get; init; } = ChargeAllocationMethods.Value;

    /// <summary>Copied from the type when the charge was saved: a later change to the type does not restate a posted invoice.</summary>
    public bool IncludeInLandedCost { get; init; }

    /// <summary>The supplier billed it on the same invoice (it is not a separate payment to make).</summary>
    public bool IncludedInSupplierInvoice { get; init; }

    public string? Notes { get; init; }

    /// <summary>What actually reached the lines. Null while nothing has been allocated yet (a draft).</summary>
    public decimal? AllocatedBase { get; init; }

    /// <summary>On a charge of an adjustment: that adjustment's status (1 Draft, 2 Posted, 3 Cancelled). Null on the invoice's own.</summary>
    public byte? AdjustmentStatus { get; init; }
}

/// <summary>One charge as the page sends it. What is left null is taken from the type or the document.</summary>
public sealed class PurchaseChargeRequest
{
    /// <summary>1-based, and what a manual allocation points at. The server renumbers from the list's order.</summary>
    public int LineNumber { get; init; }

    [Range(1, int.MaxValue)]
    public int ChargeTypeId { get; init; }

    [StringLength(200)]
    public string? Description { get; init; }

    [Range(1, int.MaxValue)]
    public int? ProviderPartyId { get; init; }

    [StringLength(100)]
    public string? Reference { get; init; }

    /// <summary>Null = the invoice's currency (an adjustment: the base currency).</summary>
    [Range(1, int.MaxValue)]
    public int? CurrencyId { get; init; }

    /// <summary>Null = 1 (Official).</summary>
    public byte? RateType { get; init; }

    /// <summary>Null = the rate of the document date; the save refuses when there is none to find.</summary>
    [Range(0.000001, 999999999)]
    public decimal? ExchangeRate { get; init; }

    [Range(0, 999999999999)]
    public decimal Amount { get; init; }

    /// <summary>Null = the charge type's own method.</summary>
    [StringLength(10)]
    public string? AllocationMethod { get; init; }

    public bool IncludedInSupplierInvoice { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>One cell of a manually allocated charge: what this invoice line takes of it, in the base currency.</summary>
public sealed class ManualAllocationRequest
{
    /// <summary>The <see cref="PurchaseChargeRequest.LineNumber"/> of the charge being split.</summary>
    public int ChargeLineNumber { get; init; }

    /// <summary>The id of a line OF THE INVOICE (not of the adjustment): that is what carries the cost.</summary>
    [Range(1, int.MaxValue)]
    public int PurchaseLineId { get; init; }

    [Range(0, 999999999999)]
    public decimal AmountBase { get; init; }
}

/// <summary>
/// The charges of a draft purchase invoice, replacing whatever was there.
///
/// SENT SEPARATELY FROM THE LINES. The lines are the supplier's bill and the charges are everybody
/// else's; they are saved by different procedures and refused for different reasons, and a freight
/// bill that arrives while the invoice is being typed should not have to wait for the goods.
/// </summary>
public sealed class SetPurchaseChargesRequest
{
    public IReadOnlyList<PurchaseChargeRequest> Charges { get; init; } = [];

    /// <summary>Only for charges whose method is Manual. They must add up to the charge's base amount.</summary>
    public IReadOnlyList<ManualAllocationRequest> ManualAllocations { get; init; } = [];

    public string? RowVersion { get; init; }
}
