using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a unit type.</summary>
public sealed class SaveUnitTypeRequest
{
    [Required]
    [StringLength(50, MinimumLength = 1)]
    public string UnitTypeName { get; init; } = string.Empty;

    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the unit type (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
