using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a brand.</summary>
public sealed class SaveBrandRequest
{
    [Required]
    [StringLength(20, MinimumLength = 1)]
    public string BrandCode { get; init; } = string.Empty;

    [Required]
    [StringLength(150, MinimumLength = 1)]
    public string BrandName { get; init; } = string.Empty;

    [StringLength(500)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the brand (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
