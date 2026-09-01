using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on an exchange rate.</summary>
public sealed class SaveExchangeRateRequest
{
    /// <summary>The quoted currency. It must exist, be active, and must not be the base currency.</summary>
    [Required]
    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    /// <summary>Official | NonOfficial | Market.</summary>
    [Required]
    public RateType RateType { get; init; }

    /// <summary>The effective date ("yyyy-MM-dd"). It cannot be in the future.</summary>
    [Required]
    public DateOnly RateDate { get; init; }

    /// <summary>1 unit of the base currency = this many units of the quoted currency.</summary>
    [Required]
    [Range(0.000001, 999999999999.999999)]
    public decimal Rate { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }

    /// <summary>Base64 ROWVERSION read with the rate (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
