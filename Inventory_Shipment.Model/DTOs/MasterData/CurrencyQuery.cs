using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the currencies list (bound from the query string).</summary>
public sealed class CurrencyQuery
{
    /// <summary>Matches Currency Code or Currency Name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Null = both active and inactive currencies.</summary>
    public bool? IsActive { get; init; }

    /// <summary>Null = the base currency and the others.</summary>
    public bool? IsBaseCurrency { get; init; }

    /// <summary>CurrencyCode | CurrencyName | DecimalPlaces | IsBaseCurrency | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "CurrencyCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
