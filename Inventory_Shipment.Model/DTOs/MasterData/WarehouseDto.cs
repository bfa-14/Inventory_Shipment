namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Public view of a warehouse, including the branch / site it belongs to.</summary>
public sealed class WarehouseDto
{
    public int Id { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public string? Address { get; init; }
    public bool IsMainWarehouse { get; init; }
    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The warehouse this one stands under; null for a root. Need not share its branch.</summary>
    public int? ParentId { get; init; }
    public string? ParentCode { get; init; }
    public string? ParentName { get; init; }

    /// <summary>Depth in the tree, 1 for a root. Maintained by the procedures, never sent in.</summary>
    public int Level { get; init; } = 1;

    /// <summary>
    /// Warehouses standing directly under this one. 0 means it is a leaf - and stock lives on the
    /// leaves, so this is what says whether the warehouse can hold any.
    /// </summary>
    public int ChildCount { get; init; }

    /// <summary>
    /// Sales invoices selling more than this warehouse holds: true allows it (after a warning), false
    /// refuses it, null follows the global setting Sales.AllowOutOfStock.
    /// </summary>
    public bool? AllowOutOfStockOverride { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>A branch / site as it appears in a dropdown.</summary>
public sealed class BranchLookupDto
{
    public int Id { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public bool IsMainBranch { get; init; }
    public bool IsActive { get; init; }
}

/// <summary>A warehouse as it appears in a dropdown.</summary>
public sealed class WarehouseLookupDto
{
    public int Id { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public bool IsMainWarehouse { get; init; }
    public bool IsActive { get; init; }

    /// <summary>So a picker can draw the tree, and offer only the leaves that may hold stock.</summary>
    public int? ParentId { get; init; }
    public int Level { get; init; } = 1;
    public int ChildCount { get; init; }
}
