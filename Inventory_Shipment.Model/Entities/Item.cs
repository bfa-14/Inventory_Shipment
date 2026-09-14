namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// An item definition (table inventory.Items) with the master-data names joined in by the
/// procedures. On Hand and the cost figures are placeholders (0 / null) until the stock and
/// purchasing modules exist.
/// </summary>
public class Item
{
    public int Id { get; set; }
    public string ItemCode { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;

    public int BrandId { get; set; }
    public string BrandName { get; set; } = string.Empty;

    public string? Model { get; set; }

    public int ItemFamilyId { get; set; }
    public string FamilyCode { get; set; } = string.Empty;
    public string FamilyName { get; set; } = string.Empty;

    /// <summary>ISO 3166-1 alpha-2 country code, e.g. "IN".</summary>
    public string CountryOfOrigin { get; set; } = string.Empty;

    public int DefaultWarehouseId { get; set; }
    public string WarehouseCode { get; set; } = string.Empty;
    public string WarehouseName { get; set; } = string.Empty;

    public string? Description { get; set; }
    public int? WarrantyMonths { get; set; }
    public int MinQuantity { get; set; }
    public int? MaxQuantity { get; set; }

    /// <summary>BIVAC-inspected item; the documents themselves belong to the shipment module.</summary>
    public bool IsBivac { get; set; }

    public bool IsActive { get; set; } = true;

    /// <summary>SKU of the base unit - only the search procedure fills it.</summary>
    public string? BaseUnitSku { get; set; }

    /// <summary>Unit type name of the base unit - only the search procedure fills it.</summary>
    public string? BaseUnitName { get; set; }

    /// <summary>Placeholder until the stock module lands; always 0 today.</summary>
    public int OnHand { get; set; }

    /// <summary>Placeholder until purchasing lands; always null today.</summary>
    public decimal? LastCost { get; set; }

    /// <summary>Placeholder until the stock module lands; always null today.</summary>
    public decimal? AverageCost { get; set; }

    /// <summary>Placeholder until purchasing lands; always null today.</summary>
    public decimal? LastPurchaseCost { get; set; }

    /// <summary>The supplier a purchase order for this item is raised on by default.</summary>
    public int? DefaultSupplierId { get; set; }
    public string? DefaultSupplierCode { get; set; }
    public string? DefaultSupplierName { get; set; }

    /// <summary>Days between ordering and receiving, for the shortage report's days-of-cover figure.</summary>
    public int? LeadTimeDays { get; set; }

    /// <summary>Who last delivered it, and when — written by the purchase invoice posting.</summary>
    public int? LastSupplierId { get; set; }
    public string? LastSupplierName { get; set; }
    public DateTime? LastPurchaseAtUtc { get; set; }

    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }
    public string? UpdatedByName { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>
/// One packing unit of an item (table inventory.ItemUnits). Exactly one unit per item is the
/// base unit and its <see cref="PackingFormula"/> is 1; every other formula says how many base
/// units that unit holds.
/// </summary>
public class ItemUnit
{
    public int Id { get; set; }
    public int ItemId { get; set; }
    public int UnitTypeId { get; set; }
    public string UnitTypeName { get; set; } = string.Empty;

    /// <summary>How many BASE units this unit holds; 1 for the base unit itself.</summary>
    public int PackingFormula { get; set; } = 1;

    /// <summary>Unique within the item.</summary>
    public string SkuCode { get; set; } = string.Empty;

    /// <summary>Unique across the whole system when present - a scanner resolves it on its own.</summary>
    public string? Barcode { get; set; }

    public bool IsSalesUnit { get; set; }
    public bool IsPurchaseUnit { get; set; }
    public bool IsBaseUnit { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>
/// A file attached to an item (table inventory.ItemFiles). At most one row per item carries
/// <see cref="IsItemImage"/>; uploading a new image replaces it. <see cref="Content"/> is filled
/// only when the file is read for download.
/// </summary>
public class ItemFile
{
    public int Id { get; set; }
    public int ItemId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public int SizeBytes { get; set; }
    public bool IsItemImage { get; set; }

    /// <summary>The bytes themselves; empty in the metadata lists returned with an item.</summary>
    public byte[] Content { get; set; } = [];

    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
}

/// <summary>One row of inventory.usp_Item_Lookup - just enough to fill an Item picker.</summary>
public sealed class ItemLookup
{
    public int Id { get; set; }
    public string ItemCode { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;
    public string? BaseUnitSku { get; set; }
    public bool IsActive { get; set; }
}
