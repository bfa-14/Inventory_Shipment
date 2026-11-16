namespace Inventory_Shipment.Model.DTOs.Reports;

/// <summary>
/// The Item Balance Report's filters (script 103). Dates are inclusive. No warehouse = every warehouse the reader may use;
/// a parent warehouse takes every warehouse under it. Items and families add up (an item chosen, or of a family chosen);
/// none of either = every item.
/// </summary>
public sealed class ItemBalanceReportQuery
{
    public int[]? WarehouseIds { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    /// <summary>The currency the amounts are shown in; empty = the base currency.</summary>
    public int? CurrencyId { get; init; }

    /// <summary>1 Official (default), 2 NonOfficial, 3 Market.</summary>
    public byte? RateType { get; init; }

    public int[]? ItemIds { get; init; }
    public int[]? FamilyIds { get; init; }

    /// <summary>Off (default): a row whose opening, movements and closing are all zero is left out.</summary>
    public bool ShowZeroBalance { get; init; }

    /// <summary>On (default): the export leaves out the movement columns with no activity (the page decides its own).</summary>
    public bool HideEmptyColumns { get; init; } = true;
}

/// <summary>The drill-down: the movements behind one cell of the report.</summary>
public sealed class ItemBalanceMovementsQuery
{
    public int ItemId { get; init; }
    public int WarehouseId { get; init; }

    /// <summary>The column's group code (GRN+, SINV-, TRF+, ADJ, ...); empty = every movement of the period.</summary>
    public string? Group { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public int? CurrencyId { get; init; }
    public byte? RateType { get; init; }
}

/// <summary>A warehouse the filter offers (the reader's own), as a tree.</summary>
public sealed class ItemBalanceWarehouseDto
{
    public int Id { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int? ParentId { get; init; }
    public int Level { get; init; }
    public bool IsTransit { get; init; }
    public bool IsActive { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public bool HasChildren { get; init; }
}

/// <summary>
/// One movement column group: a kind of movement (the document type and its direction). <c>Direction</c> In or Out
/// adds to Total In / Total Out; <c>Value</c> (ADJ, the cost adjustments: landed cost adjustments, late container charges,
/// invoice true-ups, filed under the warehouse) moves an amount and no quantity.
/// </summary>
public sealed class ItemBalanceGroupDto
{
    public string Code { get; init; } = string.Empty;
    public string Label { get; init; } = string.Empty;
    public string Direction { get; init; } = string.Empty;   // In | Out | Value
    public bool HasActivity { get; set; }
}

public sealed class ItemBalanceCellDto
{
    public long Quantity { get; set; }
    public decimal? Amount { get; set; }
}

/// <summary>
/// One item in one warehouse. Quantities are in the item's base unit, signed (out is negative); amounts are in the
/// report's currency, null for a reader without View item costs.
/// </summary>
public sealed class ItemBalanceRowDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Unit { get; init; }
    public string? FamilyName { get; init; }

    /// <summary>
    /// The warehouse the stock is in (the drill-down's key). Shown as the warehouse at the top of its tree (Code, Name)
    /// and, when it stands under another one, as that warehouse's location (LocationCode, LocationName).
    /// </summary>
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public string? LocationCode { get; init; }
    public string? LocationName { get; init; }
    public bool IsTransit { get; init; }

    public long OpeningQuantity { get; set; }
    public decimal? OpeningAmount { get; set; }

    /// <summary>By group code; only the groups the row moved in.</summary>
    public Dictionary<string, ItemBalanceCellDto> Movements { get; init; } = [];

    public long TotalInQuantity { get; set; }
    public decimal? TotalInAmount { get; set; }
    public long TotalOutQuantity { get; set; }
    public decimal? TotalOutAmount { get; set; }

    /// <summary>
    /// What the company average did to the row's stock between the opening and the closing (receipts into other
    /// warehouses, cost adjustments spread over the company's stock): what makes the row add up at the average.
    /// </summary>
    public decimal? AverageCostChange { get; set; }

    public long ClosingQuantity { get; set; }
    public decimal? ClosingAmount { get; set; }

    /// <summary>Closing amount ÷ closing quantity; null when the quantity is 0.</summary>
    public decimal? UnitCost { get; set; }

    /// <summary>The selected currency only: the closing at Date To's rate less everything else; null in the base currency.</summary>
    public decimal? TranslationDifference { get; set; }

    public bool IsNegative { get; set; }

    /// <summary>False when the opening and the movements do not give the ledger's quantity on Date To.</summary>
    public bool IntegrityOk { get; set; } = true;
    public long LedgerQuantity { get; set; }
}

public sealed class ItemBalanceTotalsDto
{
    public long OpeningQuantity { get; set; }
    public decimal? OpeningAmount { get; set; }
    public Dictionary<string, ItemBalanceCellDto> Movements { get; init; } = [];
    public long TotalInQuantity { get; set; }
    public decimal? TotalInAmount { get; set; }
    public long TotalOutQuantity { get; set; }
    public decimal? TotalOutAmount { get; set; }
    public decimal? AverageCostChange { get; set; }
    public long ClosingQuantity { get; set; }
    public decimal? ClosingAmount { get; set; }
    public decimal? TranslationDifference { get; set; }
}

public sealed class ItemBalanceCurrencyDto
{
    public int Id { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public int DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }
}

/// <summary>A rate the report used: the day it was asked for, and the rate in force then (the latest on or before it).</summary>
public sealed class ItemBalanceRateDto
{
    public DateOnly AsOf { get; init; }
    public DateOnly? RateDate { get; init; }
    public decimal Rate { get; init; }
}

public sealed class ItemBalanceReportResult
{
    public DateOnly DateFrom { get; init; }
    public DateOnly DateTo { get; init; }

    /// <summary>False without View item costs: every amount is null and the page draws quantities only.</summary>
    public bool SeesAmounts { get; init; }

    public ItemBalanceCurrencyDto? Currency { get; init; }
    public byte? RateType { get; init; }
    public string? RateTypeName { get; init; }
    public ItemBalanceRateDto? OpeningRate { get; init; }
    public ItemBalanceRateDto? ClosingRate { get; init; }

    /// <summary>The warehouses chosen ("All my warehouses" when none was).</summary>
    public string WarehousesLabel { get; init; } = string.Empty;
    public string? ItemsLabel { get; init; }

    public IReadOnlyList<ItemBalanceGroupDto> Groups { get; init; } = [];
    public IReadOnlyList<ItemBalanceRowDto> Rows { get; init; } = [];
    public ItemBalanceTotalsDto Totals { get; init; } = new();

    public int IntegrityFailures { get; init; }
    public int NegativeRows { get; init; }

    /// <summary>Where the rounded rows do not add up to the rounded total, per column ("Closing amount: rows 1,320.01, total 1,320.00").</summary>
    public IReadOnlyList<string> RoundingNotes { get; init; } = [];

    public DateTimeOffset GeneratedAtUtc { get; init; }
    public string GeneratedBy { get; init; } = string.Empty;
}

/// <summary>A movement behind a cell (the drill-down).</summary>
public sealed class ItemBalanceMovementDto
{
    public DateTime EventAt { get; init; }
    public string GroupCode { get; init; } = string.Empty;
    public string GroupLabel { get; init; } = string.Empty;
    public string? DocumentTypeCode { get; init; }
    public int? DocumentId { get; init; }
    public string? DocumentNumber { get; init; }
    public int? TransferOrderId { get; init; }
    public long Quantity { get; init; }
    public decimal? UnitCost { get; init; }
    public decimal? Amount { get; init; }
}

public sealed class ItemBalanceMovementsResult
{
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public string? CurrencyCode { get; init; }
    public IReadOnlyList<ItemBalanceMovementDto> Movements { get; init; } = [];
}
