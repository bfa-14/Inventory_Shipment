using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/// <summary>
/// How a purchase charge is spread over the lines it is bought for.
///
/// THE METHOD IS THE CHARGE'S CLAIM ABOUT WHAT DROVE IT. Freight is driven by weight, insurance by
/// value, handling by the number of packages; picking the wrong one does not break anything, it
/// quietly charges the wrong items. Weight and Volume need the figure on the item (Item Definition),
/// and the posting refuses rather than guessing when an item has none.
/// </summary>
public static class ChargeAllocationMethods
{
    public const string Value = "Value";
    public const string Quantity = "Quantity";
    public const string Weight = "Weight";
    public const string Volume = "Volume";
    public const string Manual = "Manual";

    public static readonly string[] All = [Value, Quantity, Weight, Volume, Manual];

    public static bool IsKnown(string? method)
        => method is not null && All.Contains(method, StringComparer.OrdinalIgnoreCase);

    /// <summary>The method in its canonical spelling, or null when it is not one.</summary>
    public static string? Normalize(string? method)
        => All.FirstOrDefault(m => string.Equals(m, method, StringComparison.OrdinalIgnoreCase));
}

/// <summary>One charge type (US-MD-008): what it is called, how it is allocated, and whether it reaches the item cost.</summary>
public sealed class ChargeTypeDto
{
    public int Id { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;

    /// <summary>Value | Quantity | Weight | Volume | Manual — see <see cref="ChargeAllocationMethods"/>.</summary>
    public string AllocationMethod { get; init; } = ChargeAllocationMethods.Value;

    /// <summary>False keeps the charge out of the item cost: it is recorded and paid, but the goods are not worth more for it.</summary>
    public bool IncludeInLandedCost { get; init; }

    /// <summary>A recoverable VAT is claimed back, so it is never part of the cost — the two flags cannot both be true.</summary>
    public bool IsRecoverableTax { get; init; }

    public string? Description { get; init; }
    public bool IsActive { get; init; }

    /// <summary>How many charge lines use it. ZERO IS WHAT MAKES IT DELETABLE; anything else is deactivated instead.</summary>
    public int UsageCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];

    public bool CanDelete => UsageCount == 0;
}

/// <summary>A charge type as a charge line's dropdown needs it: the defaults picking it fills in.</summary>
public sealed class ChargeTypeLookupDto
{
    public int Id { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;
    public string AllocationMethod { get; init; } = ChargeAllocationMethods.Value;
    public bool IncludeInLandedCost { get; init; }
    public bool IsRecoverableTax { get; init; }
    public bool IsActive { get; init; }
}

public sealed class ChargeTypeQuery
{
    /// <summary>Code or name (contains).</summary>
    public string? Search { get; init; }

    public string? AllocationMethod { get; init; }

    /// <summary>The "cost impact" filter: true = included in the landed cost, false = not.</summary>
    public bool? IncludeInLandedCost { get; init; }

    public bool? IsActive { get; init; }
    public string SortBy { get; init; } = "ChargeCode";
    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SaveChargeTypeRequest : IValidatableObject
{
    [Required]
    [StringLength(10, MinimumLength = 1)]
    public string ChargeCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string ChargeName { get; init; } = string.Empty;

    [Required]
    [StringLength(10)]
    public string AllocationMethod { get; init; } = ChargeAllocationMethods.Value;

    public bool IncludeInLandedCost { get; init; } = true;
    public bool IsRecoverableTax { get; init; }

    [StringLength(500)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the type (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }

    /// <summary>
    /// The two rules the shape itself can decide, said here so the page gets them as field errors
    /// rather than as a procedure's refusal: the method has to be one of the five, and a recoverable
    /// tax is never part of the item cost (the table has the same CHECK, and the procedure throws).
    /// </summary>
    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (!ChargeAllocationMethods.IsKnown(AllocationMethod))
        {
            yield return new ValidationResult(
                "Allocation method must be Value, Quantity, Weight, Volume or Manual.", [nameof(AllocationMethod)]);
        }

        if (IsRecoverableTax && IncludeInLandedCost)
        {
            yield return new ValidationResult(
                "A recoverable tax cannot be included in the landed cost.", [nameof(IncludeInLandedCost), nameof(IsRecoverableTax)]);
        }
    }
}

public sealed class SetChargeTypeActiveRequest
{
    public bool IsActive { get; init; }
    public string? RowVersion { get; init; }
}
