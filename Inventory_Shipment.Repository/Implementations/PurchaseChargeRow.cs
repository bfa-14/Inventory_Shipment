using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>
/// A charge as either procedure returns it, shared by the two that read charges.
///
/// THE INVOICE'S GET NAMES THE DOCUMENT, THE ADJUSTMENT'S DOES NOT. Reading an invoice returns its
/// own charges AND those of its adjustments, so every row has to say which it is; reading one
/// adjustment returns only its own, and repeating the same three values on every row would be
/// noise. The columns are nullable here and <see cref="ToDto"/> takes the defaults for that case.
/// </summary>
internal sealed class PurchaseChargeRow
{
    public int Id { get; init; }
    public string? DocumentKind { get; init; }
    public int? DocumentId { get; init; }
    public string? SourceNumber { get; init; }
    public int LineNumber { get; init; }
    public int ChargeTypeId { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;
    public string? Description { get; init; }
    public int? ProviderPartyId { get; init; }
    public string? ProviderName { get; init; }
    public string? Reference { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public byte RateType { get; init; }
    public decimal ExchangeRate { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public string AllocationMethod { get; init; } = ChargeAllocationMethods.Value;
    public bool IncludeInLandedCost { get; init; }
    public bool IncludedInSupplierInvoice { get; init; }
    public string? Notes { get; init; }
    public decimal? AllocatedBase { get; init; }
    public byte? AdjustmentStatus { get; init; }
    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public DateTime? ChargeDate { get; init; }
    public byte? ChargeStatus { get; init; }
    public decimal? ShareBase { get; init; }

    public PurchaseChargeDto ToDto(string? kind = null, int? documentId = null, string? sourceNumber = null) => new()
    {
        Id = Id,
        DocumentKind = DocumentKind ?? kind ?? ChargeDocumentKinds.Invoice,
        DocumentId = DocumentId ?? documentId ?? 0,
        SourceNumber = SourceNumber ?? sourceNumber,
        LineNumber = LineNumber,
        ChargeTypeId = ChargeTypeId,
        ChargeCode = ChargeCode,
        ChargeName = ChargeName,
        Description = Description,
        ProviderPartyId = ProviderPartyId,
        ProviderName = ProviderName,
        Reference = Reference,
        CurrencyId = CurrencyId,
        CurrencyCode = CurrencyCode,
        RateType = RateType,
        ExchangeRate = ExchangeRate,
        Amount = Amount,
        AmountBase = AmountBase,
        AllocationMethod = AllocationMethod,
        IncludeInLandedCost = IncludeInLandedCost,
        IncludedInSupplierInvoice = IncludedInSupplierInvoice,
        Notes = Notes,
        AllocatedBase = AllocatedBase,
        AdjustmentStatus = AdjustmentStatus,
        ContainerId = ContainerId,
        ContainerRef = ContainerRef,
        ChargeDate = ChargeDate,
        ChargeStatus = ChargeStatus,
        ShareBase = ShareBase,
    };
}
