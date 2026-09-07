using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the price lists list (bound from the query string).</summary>
public sealed class PriceListQuery
{
    /// <summary>Matches Price List Code or Price List Name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Null = every currency.</summary>
    public int? CurrencyId { get; init; }

    /// <summary>Null = both active and inactive price lists.</summary>
    public bool? IsActive { get; init; }

    /// <summary>PriceListCode | PriceListName | CurrencyCode | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "PriceListCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
