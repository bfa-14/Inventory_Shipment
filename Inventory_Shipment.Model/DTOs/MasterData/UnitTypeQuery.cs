using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the unit types list (bound from the query string).</summary>
public sealed class UnitTypeQuery
{
    /// <summary>Matches the unit type name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Null = both active and inactive unit types.</summary>
    public bool? IsActive { get; init; }

    /// <summary>UnitTypeName | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "UnitTypeName";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
