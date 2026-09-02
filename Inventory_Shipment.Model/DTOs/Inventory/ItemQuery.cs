using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>Filters, sorting and paging for the Item Definition list (bound from the query string).</summary>
public sealed class ItemQuery
{
    /// <summary>Matches Item Code, Item Name, or the SKU / barcode of any of the item's units (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Matches the family AND its whole subtree, so filtering a parent finds its children's items.</summary>
    public int? ItemFamilyId { get; init; }

    public int? BrandId { get; init; }
    public int? DefaultWarehouseId { get; init; }

    /// <summary>Null = both active and inactive items.</summary>
    public bool? IsActive { get; init; }

    /// <summary>Null = both BIVAC and non-BIVAC items.</summary>
    public bool? IsBivac { get; init; }

    /// <summary>ItemCode | ItemName | BrandName | FamilyName | WarehouseName | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "ItemCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
