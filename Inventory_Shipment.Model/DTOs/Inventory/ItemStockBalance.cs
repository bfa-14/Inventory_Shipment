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

/// <summary>One movement of an item on its stock statement, with the balance after it.</summary>
public sealed class ItemStockMovementDto
{
    public long Id { get; init; }
    public DateTime MovementDate { get; init; }

    /// <summary>Inventory | Sales | Purchase - with the type and id, what the row links to.</summary>
    public string DocumentFamily { get; init; } = string.Empty;
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string? DocumentTypeName { get; init; }
    public int DocumentId { get; init; }
    public string? DocumentNumber { get; init; }

    /// <summary>The movement written back when its document was cancelled.</summary>
    public bool IsReversal { get; init; }

    public string? ReasonCode { get; init; }
    public DateTime? ExpiryDate { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public int QuantityIn { get; init; }
    public int QuantityOut { get; init; }

    /// <summary>The balance after this movement, from the statement's opening balance.</summary>
    public int Balance { get; init; }

    public decimal? UnitCostBase { get; init; }

    /// <summary>The client of a sale or the supplier of a purchase; null for Inventory In / Out.</summary>
    public string? Counterparty { get; init; }

    public string? CreatedByName { get; init; }
}

/// <summary>
/// An item's stock statement: the balance brought forward, every movement in the range with the
/// running balance, and what came in, went out and is left.
/// </summary>
public sealed class ItemStockStatementDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int OpeningBase { get; init; }
    public int TotalIn { get; init; }
    public int TotalOut { get; init; }
    public int ClosingBase { get; init; }
    public IReadOnlyList<ItemStockMovementDto> Movements { get; init; } = [];
}