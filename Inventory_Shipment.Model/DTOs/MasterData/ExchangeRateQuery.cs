using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the exchange rates list (bound from the query string).</summary>
public sealed class ExchangeRateQuery
{
    /// <summary>Null = rates of every currency.</summary>
    public int? CurrencyId { get; init; }

    /// <summary>Null = Official, Non-official and Market rates.</summary>
    public RateType? RateType { get; init; }

    /// <summary>Only rates effective on or after this date.</summary>
    public DateOnly? DateFrom { get; init; }

    /// <summary>Only rates effective on or before this date.</summary>
    public DateOnly? DateTo { get; init; }

    /// <summary>RateDate | CurrencyCode | RateType | Rate | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "RateDate";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "desc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
