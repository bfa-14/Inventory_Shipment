using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>Body of both POST (create) and PUT (update) on an item. Units and files have their own endpoints.</summary>
public sealed class SaveItemRequest
{
    [Required]
    [StringLength(30, MinimumLength = 1)]
    public string ItemCode { get; init; } = string.Empty;

    [Required]
    [StringLength(200, MinimumLength = 1)]
    public string ItemName { get; init; } = string.Empty;

    [Range(1, int.MaxValue)]
    public int BrandId { get; init; }

    [StringLength(100)]
    public string? Model { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemFamilyId { get; init; }

    /// <summary>ISO 3166-1 alpha-2 country code, e.g. "IN". Stored upper-case.</summary>
    [Required]
    [RegularExpression("^[A-Za-z]{2}$", ErrorMessage = "Country of Origin must be a 2-letter ISO country code.")]
    public string CountryOfOrigin { get; init; } = string.Empty;

    [Range(1, int.MaxValue)]
    public int DefaultWarehouseId { get; init; }

    [StringLength(1000)]
    public string? Description { get; init; }

    [Range(0, 600)]
    public int? WarrantyMonths { get; init; }

    [Range(0, int.MaxValue)]
    public int MinQuantity { get; init; }

    [Range(0, int.MaxValue)]
    public int? MaxQuantity { get; init; }

    /// <summary>BIVAC-inspected item; the documents themselves belong to the shipment module.</summary>
    public bool IsBivac { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>The supplier a purchase order is raised on by default. Must be an active party flagged as a supplier.</summary>
    [Range(1, int.MaxValue)]
    public int? DefaultSupplierId { get; init; }

    /// <summary>Days between ordering and receiving.</summary>
    [Range(0, 3650)]
    public int? LeadTimeDays { get; init; }

    /// <summary>Pieces (base units) that fit in one container; the shortage plan turns a required quantity into containers with it.</summary>
    [Range(1, int.MaxValue)]
    public int? PcPerContainer { get; init; }

    /// <summary>Per BASE unit. Needed by charges allocated by weight; null leaves those charges unable to allocate.</summary>
    [Range(0, 9999999)]
    public decimal? WeightKg { get; init; }

    /// <summary>Per BASE unit, in cubic metres. The same, for charges allocated by volume.</summary>
    [Range(0, 9999999)]
    public decimal? VolumeCbm { get; init; }

    /// <summary>Base64 ROWVERSION read with the item (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
