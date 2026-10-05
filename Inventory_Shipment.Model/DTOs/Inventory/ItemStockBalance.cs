namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>
/// One item's stock in one warehouse - a row of the item card's Stock Balance page.
///
/// EVERY WAREHOUSE THAT HAS HELD THE ITEM, zero included, so a warehouse that has just been emptied
/// still shows rather than vanishing. The value is the quantity at the item's moving average cost.
/// </summary>
public sealed class ItemStockBalanceRowDto
{
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public bool WarehouseIsActive { get; init; }
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;

    /// <summary>In base units. Negative when out-of-stock selling took it below zero.</summary>
    public decimal OnHandBase { get; init; }

    public DateTime? LastMovementAtUtc { get; init; }
    public decimal? AverageCost { get; init; }
    public decimal InventoryValue { get; init; }
}

/// <summary>The item, its stock per warehouse, and the totals across them.</summary>
public sealed class ItemStockBalanceDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public IReadOnlyList<ItemStockBalanceRowDto> Warehouses { get; init; } = [];
    public decimal TotalOnHandBase { get; init; }
    public decimal TotalInventoryValue { get; init; }
}
