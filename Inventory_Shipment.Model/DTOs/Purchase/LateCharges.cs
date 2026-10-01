using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/// <summary>
/// One charge that arrives after a LOCAL purchase invoice was posted — the freight bill three weeks
/// late — as the invoice page enters it.
///
/// THERE IS NO SEPARATE DOCUMENT TO OPEN FIRST. The charge goes into the invoice's open draft landed
/// cost adjustment, which is created on the first one; posting that adjustment is what moves the
/// value. A late charge is a landed cost adjustment seen from the invoice, not a second mechanism.
/// </summary>
public sealed class SaveLateChargeRequest
{
    [Range(1, int.MaxValue)]
    public int ChargeTypeId { get; init; }

    [StringLength(200)]
    public string? Description { get; init; }

    [Range(1, int.MaxValue)]
    public int? ProviderPartyId { get; init; }

    /// <summary>The provider's invoice or receipt number.</summary>
    [StringLength(100)]
    public string? Reference { get; init; }

    /// <summary>
    /// Becomes the date of the draft adjustment (an adjustment has one date, the charge has none of
    /// its own), and the date the exchange rate is read at when <see cref="ExchangeRate"/> is null.
    /// </summary>
    [Required]
    public DateOnly? ChargeDate { get; init; }

    /// <summary>Null = the base currency.</summary>
    [Range(1, int.MaxValue)]
    public int? CurrencyId { get; init; }

    /// <summary>Null = 1 (Official).</summary>
    public byte? RateType { get; init; }

    /// <summary>Null = the rate of the charge date.</summary>
    [Range(0.000001, 999999999)]
    public decimal? ExchangeRate { get; init; }

    [Range(typeof(decimal), "0.01", "999999999999")]
    public decimal Amount { get; init; }

    /// <summary>Null = the charge type's own method. Manual is not offered: a late charge has no split grid.</summary>
    [StringLength(10)]
    public string? AllocationMethod { get; init; }

    /// <summary>
    /// Null = the charge type's flag. The flag is the TYPE's (the writer copies it on every save), so a
    /// value that differs from the type's is refused rather than silently ignored.
    /// </summary>
    public bool? IncludeInLandedCost { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>The open draft adjustment of an invoice: what "Post late charges" will post.</summary>
public sealed class LateChargeDraftDto
{
    public int Id { get; init; }
    public string Number { get; init; } = string.Empty;
    public DateTime Date { get; init; }

    /// <summary>Sent back with the post, so charges added by somebody else meanwhile are not posted unseen.</summary>
    public byte[] RowVersion { get; init; } = [];

    /// <summary>The charges that reach the item cost, in the base currency: what posting will add.</summary>
    public decimal TotalBase { get; init; }
}

/// <summary>One late charge of the invoice, whatever became of its adjustment.</summary>
public sealed class LateChargeDto
{
    /// <summary>The charge's id. A DRAFT adjustment's charges are rewritten on every save, so their ids change with it.</summary>
    public int Id { get; init; }

    public int AdjustmentId { get; init; }
    public string AdjustmentNumber { get; init; } = string.Empty;

    /// <summary>The adjustment's: Draft, Posted or Cancelled — see <see cref="LandedCostAdjustmentStatus"/>.</summary>
    public string Status { get; init; } = LandedCostAdjustmentStatus.Draft;

    public DateTime? PostedAtUtc { get; init; }

    /// <summary>1-based within its adjustment — the "Charge N:" of the server's refusals.</summary>
    public int LineNumber { get; init; }

    public int ChargeTypeId { get; init; }
    public string ChargeTypeCode { get; init; } = string.Empty;
    public string ChargeTypeName { get; init; } = string.Empty;
    public string? Description { get; init; }
    public int? ProviderPartyId { get; init; }
    public string? ProviderName { get; init; }
    public string? Reference { get; init; }

    /// <summary>The adjustment's date.</summary>
    public DateTime ChargeDate { get; init; }

    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public byte RateType { get; init; }
    public decimal ExchangeRate { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public string AllocationMethod { get; init; } = ChargeAllocationMethods.Value;
    public bool IncludeInLandedCost { get; init; }
    public string? Notes { get; init; }

    /// <summary>What reached the invoice lines. Null until the adjustment is posted.</summary>
    public decimal? AllocatedBase { get; init; }

    public bool CanEdit => Status == LandedCostAdjustmentStatus.Draft;
}

public sealed class LateChargesDto
{
    /// <summary>Null when every late charge of the invoice has been posted (or there are none).</summary>
    public LateChargeDraftDto? DraftAdjustment { get; init; }

    /// <summary>Every adjustment's charges, the newest adjustment first.</summary>
    public IReadOnlyList<LateChargeDto> Charges { get; init; } = [];
}

public sealed class PostLateChargesRequest
{
    /// <summary>The draft adjustment's, as the page last read it. Null skips the check.</summary>
    public string? RowVersion { get; init; }
}

/// <summary>One invoice line as the posting moved it: its landed cost per base unit, and where the value went.</summary>
public sealed class LateChargePostedLineDto
{
    public int LineNo { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string WarehouseCode { get; init; } = string.Empty;
    public decimal LandedCostBefore { get; init; }
    public decimal LandedCostAfter { get; init; }

    /// <summary>The part still in stock: it raised the item's average cost.</summary>
    public decimal InventoryPortionBase { get; init; }

    /// <summary>The part already sold: it went to the period's cost of goods sold.</summary>
    public decimal CogsPortionBase { get; init; }
}

public sealed class LateChargesPostedDto
{
    public int AdjustmentId { get; init; }
    public string AdjustmentNumber { get; init; } = string.Empty;
    public IReadOnlyList<LateChargePostedLineDto> Lines { get; init; } = [];
}
