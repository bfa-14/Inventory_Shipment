using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>
/// Body of both POST (add) and PUT (edit) on an item unit. The first unit of an item must be the
/// base unit; marking another unit as the base afterwards demotes the current one automatically.
/// </summary>
public sealed class SaveItemUnitRequest
{
    [Range(1, int.MaxValue)]
    public int UnitTypeId { get; init; }

    /// <summary>How many base units this unit holds. Must be 1 for the base unit.</summary>
    [Range(1, int.MaxValue)]
    public int PackingFormula { get; init; } = 1;

    [Required]
    [StringLength(50, MinimumLength = 1)]
    public string SkuCode { get; init; } = string.Empty;

    [StringLength(50)]
    public string? Barcode { get; init; }

    public bool IsSalesUnit { get; init; }
    public bool IsPurchaseUnit { get; init; }
    public bool IsBaseUnit { get; init; }

    /// <summary>Base64 ROWVERSION read with the unit (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
