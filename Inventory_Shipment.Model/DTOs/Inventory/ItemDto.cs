namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>One row of the Item Definition list.</summary>
public sealed class ItemListDto
{
    public int Id { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    public int BrandId { get; init; }
    public string BrandName { get; init; } = string.Empty;

    public string? Model { get; init; }

    public int ItemFamilyId { get; init; }
    public string FamilyCode { get; init; } = string.Empty;
    public string FamilyName { get; init; } = string.Empty;

    public string CountryOfOrigin { get; init; } = string.Empty;

    public int DefaultWarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;

    /// <summary>Unit type name of the item's base unit; null while the item has no unit yet.</summary>
    public string? BaseUnitName { get; init; }

    /// <summary>SKU of the item's base unit; null while the item has no unit yet.</summary>
    public string? BaseUnitSku { get; init; }

    /// <summary>Placeholder until the stock module lands; always 0 today.</summary>
    public int OnHand { get; init; }

    public bool IsBivac { get; init; }
    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>An item with its units and the metadata of its files - what the details page reads.</summary>
public sealed class ItemDetailsDto
{
    public int Id { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    public int BrandId { get; init; }
    public string BrandName { get; init; } = string.Empty;

    public string? Model { get; init; }

    public int ItemFamilyId { get; init; }
    public string FamilyCode { get; init; } = string.Empty;
    public string FamilyName { get; init; } = string.Empty;

    public string CountryOfOrigin { get; init; } = string.Empty;

    public int DefaultWarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;

    public string? Description { get; init; }
    public int? WarrantyMonths { get; init; }
    public int MinQuantity { get; init; }
    public int? MaxQuantity { get; init; }
    public bool IsBivac { get; init; }
    public bool IsActive { get; init; }

    /// <summary>Placeholder until the stock module lands; always 0 today.</summary>
    public int OnHand { get; init; }

    /// <summary>Placeholder until purchasing lands; always null today.</summary>
    public decimal? LastCost { get; init; }

    /// <summary>Placeholder until the stock module lands; always null today.</summary>
    public decimal? AverageCost { get; init; }

    /// <summary>Placeholder until purchasing lands; always null today.</summary>
    public decimal? LastPurchaseCost { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;

    /// <summary>Base unit first, then the packing units ordered by formula.</summary>
    public IReadOnlyList<ItemUnitDto> Units { get; init; } = [];

    /// <summary>The item image (when present) first, then the attachments, newest first.</summary>
    public IReadOnlyList<ItemFileDto> Files { get; init; } = [];
}

/// <summary>One packing unit of an item.</summary>
public sealed class ItemUnitDto
{
    public int Id { get; init; }
    public int ItemId { get; init; }
    public int UnitTypeId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;

    /// <summary>How many base units this unit holds; 1 for the base unit itself.</summary>
    public int PackingFormula { get; init; }

    public string SkuCode { get; init; } = string.Empty;
    public string? Barcode { get; init; }
    public bool IsSalesUnit { get; init; }
    public bool IsPurchaseUnit { get; init; }
    public bool IsBaseUnit { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>Metadata of one item file; the bytes come from the download endpoint.</summary>
public sealed class ItemFileDto
{
    public int Id { get; init; }
    public int ItemId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }

    /// <summary>True for the single item image; false for an ordinary attachment.</summary>
    public bool IsItemImage { get; init; }

    public DateTime CreatedAtUtc { get; init; }
}

/// <summary>An item as it appears in a dropdown.</summary>
public sealed class ItemLookupDto
{
    public int Id { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? BaseUnitSku { get; init; }
    public bool IsActive { get; init; }
}
