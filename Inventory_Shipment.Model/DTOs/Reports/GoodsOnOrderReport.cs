using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Model.DTOs.Reports;

/// <summary>
/// Reports › Goods on Order (script 109): everything ordered and not received yet, one row per item, one Qty / Containers
/// pair per STAGE THE GOODS ARE AT NOW. The stages are the Container Report's (logistics.usp_ContainerReport's StageLabel,
/// worked out from the containers' movements), the order months of "Order pending" in one column: the columns follow the
/// journey the containers really make, a stage nobody is at is no column.
/// </summary>
public sealed class GoodsOnOrderReportQuery
{
    public int? SupplierId { get; init; }
    public int? ItemFamilyId { get; init; }
    public int? ItemId { get; init; }
    public int? BranchId { get; init; }

    /// <summary>Orders dated up to this day only (the older orders); null = every order.</summary>
    public DateOnly? OrderDateTo { get; init; }

    /// <summary>Container ref or number, B/L, order number, PI number, invoice number.</summary>
    public string? Search { get; init; }
}

/// <summary>A column: one stage of the journey.</summary>
public sealed class GoodsOnOrderStageDto
{
    /// <summary>"Pending" for every order month, else the stage's label: the key of the cells.</summary>
    public string Key { get; init; } = string.Empty;

    /// <summary>"Order pending", "In transit Chennai → Dar es Salaam", "Dar es Salaam", "Dar es Salaam → Mokambo".</summary>
    public string Label { get; init; } = string.Empty;

    /// <summary>The order of the journey (the Container Report's StageSort): pending, at sea, at port, on the road, delivered.</summary>
    public decimal Sort { get; init; }

    /// <summary>Pending, AtSea, AtPort, OnTheRoad, AtPlace (a border, customs or inland stay), Delivered.</summary>
    public string Kind { get; init; } = string.Empty;
}

/// <summary>What an item (a family, the whole report) has at one stage.</summary>
public sealed class GoodsOnOrderCellDto
{
    public int Quantity { get; init; }

    /// <summary>The containers carrying them (a container of two items counts in both items, once in a total).</summary>
    public int Containers { get; init; }

    /// <summary>Pieces still on an order line, on no container yet ("Order pending" only).</summary>
    public int PiecesNotLoaded { get; init; }

    /// <summary>
    /// Their containers, estimated: pieces ÷ the item's container unit, rounded up per item. Null when some of those pieces
    /// belong to an item without a container unit (spare parts): only its planned containers are counted.
    /// </summary>
    public int? EstimatedContainers { get; init; }

    /// <summary>Pieces not loaded of an item without a container unit: their containers are unknown.</summary>
    public bool EstimateIncomplete { get; init; }
}

public sealed class GoodsOnOrderItemDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? RootFamilyName { get; init; }

    /// <summary>The item's pieces per container, null when it has no Container unit.</summary>
    public decimal? PcsPerContainer { get; init; }

    /// <summary>By stage key; only the stages the item is at.</summary>
    public IReadOnlyDictionary<string, GoodsOnOrderCellDto> Cells { get; init; } = new Dictionary<string, GoodsOnOrderCellDto>();
    public GoodsOnOrderCellDto Total { get; init; } = new();
}

public sealed class GoodsOnOrderFamilyDto
{
    /// <summary>"Main Items" (the vehicles), "Maintenance and Accessories", "No family".</summary>
    public string RootFamilyName { get; init; } = string.Empty;
    public IReadOnlyDictionary<string, GoodsOnOrderCellDto> Cells { get; init; } = new Dictionary<string, GoodsOnOrderCellDto>();
    public GoodsOnOrderCellDto Total { get; init; } = new();
}

public sealed class GoodsOnOrderReportResult
{
    /// <summary>The columns, in the order of the journey.</summary>
    public IReadOnlyList<GoodsOnOrderStageDto> Stages { get; init; } = [];

    /// <summary>Grouped by top family, then by item code.</summary>
    public IReadOnlyList<GoodsOnOrderItemDto> Items { get; init; } = [];
    public IReadOnlyList<GoodsOnOrderFamilyDto> Families { get; init; } = [];

    /// <summary>Every item: its Containers are the general total of containers (each container once).</summary>
    public IReadOnlyDictionary<string, GoodsOnOrderCellDto> Totals { get; init; } = new Dictionary<string, GoodsOnOrderCellDto>();
    public GoodsOnOrderCellDto GrandTotal { get; init; } = new();

    /// <summary>The Container Report's rows behind the figures (for the drill-down), with <see cref="StageKeys"/>.</summary>
    public IReadOnlyList<ContainerReportRowDto> Rows { get; init; } = [];

    /// <summary>Each row's stage key, by its RowKey.</summary>
    public IReadOnlyDictionary<string, string> StageKeys { get; init; } = new Dictionary<string, string>();

    public DateTimeOffset GeneratedAtUtc { get; init; }
    public string GeneratedBy { get; init; } = string.Empty;
}
