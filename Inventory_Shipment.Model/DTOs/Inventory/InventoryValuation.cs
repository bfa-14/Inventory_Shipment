namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>
/// One item's stock and what it is worth: on hand × average cost.
///
/// THE AVERAGE IS THE ITEM'S, not the warehouse's. A moving average is kept per item, so the value
/// of one warehouse's stock is that warehouse's quantity at the company-wide average — which is
/// what the ledger charges a sale out of any warehouse at.
/// </summary>
public sealed class InventoryValuationRowDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>Null on the company-wide view (every warehouse together).</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public decimal OnHandBase { get; init; }
    public decimal? AverageCost { get; init; }
    public decimal InventoryValue { get; init; }
}

/// <summary>The valuation rows and what they add up to, so the page does not have to sum a page of them.</summary>
public sealed class InventoryValuationResult
{
    public IReadOnlyList<InventoryValuationRowDto> Items { get; init; } = [];

    /// <summary>Items with stock on hand (a zero-stock item is listed but does not count as a line of inventory).</summary>
    public int ItemsWithStock { get; init; }

    public decimal TotalOnHandBase { get; init; }
    public decimal TotalInventoryValue { get; init; }

    /// <summary>Null on the company-wide view.</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseName { get; init; }
}
