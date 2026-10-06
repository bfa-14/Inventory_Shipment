using Inventory_Shipment.Model.DTOs.Purchase;

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

/// <summary>One purchase order with the item on it, and what it asks for of that item.</summary>
public sealed class ItemPurchaseOrderDto
{
    public int DocumentId { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public DateTime? ExpectedDate { get; init; }
    public byte StatusCode { get; init; }

    /// <summary>Draft | PendingApproval | Posted | Closed | Cancelled.</summary>
    public string Status => PurchaseDocumentStatus.From(StatusCode);

    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public string CurrencyCode { get; init; } = string.Empty;
    public byte DecimalPlaces { get; init; }

    /// <summary>The order's lines of this item, added up, in base units.</summary>
    public int OrderedBase { get; init; }
    public int ReceivedBase { get; init; }

    /// <summary>Still to come: ordered less received, on an open (Posted) order only.</summary>
    public int OutstandingBase { get; init; }

    /// <summary>What the order pays for this item, in the order's currency.</summary>
    public decimal Amount { get; init; }
}

/// <summary>The item's purchase orders and what they add up to.</summary>
public sealed class ItemPurchaseOrdersDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>Posted orders still waiting for some of the item.</summary>
    public int OpenOrders { get; init; }

    /// <summary>On order: what open orders have still to deliver, in base units.</summary>
    public int OutstandingBase { get; init; }

    /// <summary>Ordered and received across every order that was not cancelled.</summary>
    public int OrderedBase { get; init; }
    public int ReceivedBase { get; init; }
    public IReadOnlyList<ItemPurchaseOrderDto> Orders { get; init; } = [];
}

/// <summary>One container carrying the item, and how much of the item it holds.</summary>
public sealed class ItemContainerDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }

    /// <summary>1 Draft, 2 Confirmed, 3 In Transit, 4 At Port, 5 Cleared, 6 Offloaded, 7 Closed, 8 Cancelled.</summary>
    public byte StatusCode { get; init; }

    public string? ContainerTypeName { get; init; }
    public DateTime? OrderDate { get; init; }
    public DateTime? DispatchDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public string? BranchName { get; init; }
    public string? WarehouseName { get; init; }
    public int? PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }

    /// <summary>The container's lines of this item, added up, in base units.</summary>
    public int LoadedBase { get; init; }
    public int ReceivedBase { get; init; }

    /// <summary>Loaded less received, on a container from Confirmed to Cleared only.</summary>
    public int OnTheWayBase { get; init; }
}

/// <summary>The item's containers and what they add up to.</summary>
public sealed class ItemContainersDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>Containers still bringing some of the item.</summary>
    public int ContainersOnTheWay { get; init; }

    /// <summary>What those containers are still bringing, in base units.</summary>
    public int OnTheWayBase { get; init; }

    /// <summary>Loaded and received across every container that was not cancelled.</summary>
    public int LoadedBase { get; init; }
    public int ReceivedBase { get; init; }
    public IReadOnlyList<ItemContainerDto> Containers { get; init; } = [];
}