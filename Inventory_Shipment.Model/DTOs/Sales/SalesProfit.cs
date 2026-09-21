namespace Inventory_Shipment.Model.DTOs.Sales;

/// <summary>What the profit report can be grouped by. The label a row carries depends on this.</summary>
public static class SalesProfitGroupings
{
    public const string Invoice = "Invoice";
    public const string Item = "Item";
    public const string Family = "Family";
    public const string Brand = "Brand";
    public const string Client = "Client";
    public const string Salesman = "Salesman";
    public const string Branch = "Branch";
    public const string Month = "Month";
    public const string All = "All";

    public static readonly string[] Known = [Invoice, Item, Family, Brand, Client, Salesman, Branch, Month, All];

    public static string? Normalize(string? groupBy)
        => Known.FirstOrDefault(g => string.Equals(g, groupBy, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// One group of the profit report, in the BASE currency.
///
/// EVERY FIGURE IS FROZEN, not recomputed. Cost of sales is what each line was worth when it was
/// posted, so a report run today and the same report run next year agree — which is the point of
/// freezing the cost on the line rather than reading the item's average now.
/// Returns subtract: a returned line takes its own sale and its own cost back out.
/// </summary>
public sealed class SalesProfitRowDto
{
    /// <summary>The identity of the group (an id, a month "2026-09", or "ALL"). Stable; the label is for reading.</summary>
    public string GroupKey { get; init; } = string.Empty;

    public string GroupLabel { get; init; } = string.Empty;
    public int InvoiceCount { get; init; }
    public int ReturnCount { get; init; }
    public decimal QuantityBase { get; init; }
    public decimal GrossSalesBase { get; init; }
    public decimal DiscountBase { get; init; }
    public decimal NetSalesBase { get; init; }
    public decimal CogsBase { get; init; }
    public decimal GrossProfitBase { get; init; }

    /// <summary>On net sales. Null when nothing was sold in the group (no denominator).</summary>
    public decimal? GrossProfitPct { get; init; }

    /// <summary>
    /// Cost of sales that belongs to no invoice: the already-sold part of a landed cost adjustment.
    /// Only filled for the groupings a cost adjustment can be attributed to (Month, Branch, Item,
    /// Family, Brand, All) — an adjustment knows its item and its date, never its invoice.
    /// </summary>
    public decimal CogsAdjustmentsBase { get; init; }
}

public sealed class SalesProfitQuery
{
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public int? BranchId { get; init; }
    public int? ClientId { get; init; }
    public int? SalesmanId { get; init; }
    public int? ItemFamilyId { get; init; }
    public int? BrandId { get; init; }
    public int? ItemId { get; init; }

    /// <summary>Invoice | Item | Family | Brand | Client | Salesman | Branch | Month | All.</summary>
    public string GroupBy { get; init; } = SalesProfitGroupings.Invoice;
}
