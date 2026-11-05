using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Model.DTOs.Reports;

/// <summary>
/// Reports › Dispatched Items (script 106): the items dispatched in a period - by default from India - in two views, the
/// item balance (<see cref="DispatchedItemsReportResult.Items"/>) and the items / containers
/// (<see cref="DispatchedItemsReportResult.Rows"/>, the Container Report's rows). The purchasing team's "DISPATCH FROM
/// INDIA" sheet, worked out by the system.
///
/// AMOUNTS ARE IN THE BASE CURRENCY. A figure the reader may not see is null, never 0: the deduction (oil) without View
/// Container Charges, the payments without View Supplier Payments.
/// </summary>
public sealed class DispatchedItemsReportQuery
{
    /// <summary>The container's dispatch date (the first start of its Sea leg, or typed), inclusive. Both required.</summary>
    public DateOnly? DispatchFrom { get; init; }
    public DateOnly? DispatchTo { get; init; }

    /// <summary>"IN" (the default on the page): the country of the port of loading, else of origin. Empty = any.</summary>
    public string? LoadingCountry { get; init; }

    public int? SupplierId { get; init; }
    public int? ItemFamilyId { get; init; }
    public int? ItemId { get; init; }

    /// <summary>Container ref or number, B/L, order number, PI number, invoice number.</summary>
    public string? Search { get; init; }

    /// <summary>Where the goods are now: All, AtSea, AtPort, OnTheRoad, Offloaded.</summary>
    public string? Location { get; init; }
}

/// <summary>Where a dispatched container line is now, from its stage (the Container Report's StageSort) and status.</summary>
public static class DispatchedLocation
{
    public const string AtSea = "AtSea";
    public const string AtPort = "AtPort";
    public const string OnTheRoad = "OnTheRoad";
    public const string Offloaded = "Offloaded";
}

/// <summary>A row of the item balance: one item over the containers dispatched in the period.</summary>
public sealed class DispatchedItemDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? ItemFamilyName { get; init; }

    /// <summary>"Main Items" (the vehicles), "Maintenance and Accessories": the quantity is added up per top family.</summary>
    public string? RootFamilyName { get; init; }

    /// <summary>The containers holding the item; a container of two items counts in both rows, once in the totals.</summary>
    public int Containers { get; init; }
    public int Quantity { get; init; }
    public decimal FobAmountBase { get; init; }

    /// <summary>True when a line's FOB is still an estimate (not received yet).</summary>
    public bool FobIsEstimate { get; init; }

    /// <summary>FOB ÷ quantity.</summary>
    public decimal? FobPerUnitBase { get; init; }

    /// <summary>The oil quantity typed on its container lines; null when none is typed.</summary>
    public decimal? OilQty { get; init; }

    /// <summary>The container lines with "oil included" ticked.</summary>
    public int OilIncludedLines { get; init; }

    /// <summary>Its share of the posted deduction charges (oil), positive; null without View Container Charges.</summary>
    public decimal? DeductionBase { get; init; }

    /// <summary>Pieces at each place now.</summary>
    public int AtSea { get; init; }
    public int AtPort { get; init; }
    public int OnTheRoad { get; init; }
    public int Offloaded { get; init; }
}

/// <summary>The quantity of one top family ("Main Items: 5,076") and its containers and FOB.</summary>
public sealed class DispatchedFamilyTotalDto
{
    public string RootFamilyName { get; init; } = string.Empty;
    public int Containers { get; init; }
    public int Quantity { get; init; }
    public decimal FobAmountBase { get; init; }
    public decimal? DeductionBase { get; init; }
}

public sealed class DispatchedItemsTotalsDto
{
    /// <summary>Distinct containers.</summary>
    public int Containers { get; init; }
    public decimal FobAmountBase { get; init; }
    public decimal? OilQty { get; init; }
    public decimal? DeductionBase { get; init; }

    /// <summary>Distinct containers at each place now.</summary>
    public int ContainersAtSea { get; init; }
    public int ContainersAtPort { get; init; }
    public int ContainersOnTheRoad { get; init; }
    public int ContainersOffloaded { get; init; }
}

public sealed class DispatchedItemsReportResult
{
    public DateOnly DispatchFrom { get; init; }
    public DateOnly DispatchTo { get; init; }
    public string? LoadingCountry { get; init; }

    public IReadOnlyList<DispatchedItemDto> Items { get; init; } = [];
    public IReadOnlyList<DispatchedFamilyTotalDto> Families { get; init; } = [];
    public DispatchedItemsTotalsDto Totals { get; init; } = new();
    public IReadOnlyList<ContainerReportRowDto> Rows { get; init; } = [];

    /// <summary>Each row's <see cref="DispatchedLocation"/>, by its RowKey.</summary>
    public IReadOnlyDictionary<string, string> Locations { get; init; } = new Dictionary<string, string>();

    /// <summary>The deduction charge type's name ("OIL Deduction / refund"); null when there is none.</summary>
    public string? DeductionName { get; init; }

    /// <summary>False without View Container Charges: the deduction columns are left out.</summary>
    public bool DeductionVisible { get; init; }

    /// <summary>False without View Supplier Payments: the payment columns are left out.</summary>
    public bool PaymentsVisible { get; init; }

    public string BaseCurrencyCode { get; init; } = "USD";
    public DateTimeOffset GeneratedAtUtc { get; init; }
    public string GeneratedBy { get; init; } = string.Empty;
}
