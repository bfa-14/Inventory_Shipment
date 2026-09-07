using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a price list.</summary>
public sealed class SavePriceListRequest
{
    [Required]
    [StringLength(20, MinimumLength = 1)]
    public string PriceListCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string PriceListName { get; init; } = string.Empty;

    /// <summary>masterdata.Currencies.Id - required and must be active.</summary>
    [Required]
    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    [StringLength(500)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the price list (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
