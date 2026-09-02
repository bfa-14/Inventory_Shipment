using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the brands list (bound from the query string).</summary>
public sealed class BrandQuery
{
    /// <summary>Matches Brand Code or Brand Name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Null = both active and inactive brands.</summary>
    public bool? IsActive { get; init; }

    /// <summary>BrandCode | BrandName | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "BrandCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
