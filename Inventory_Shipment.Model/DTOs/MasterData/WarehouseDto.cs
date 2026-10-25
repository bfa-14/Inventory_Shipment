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

    /// <summary>
    /// (90) The "On the way" warehouse of its branch, managed by transfer orders: only its name and address may be
    /// changed, and it is never deactivated or deleted on its own.
    /// </summary>
    public bool IsTransit { get; init; }

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

    /// <summary>Already used in transactions: it cannot be chosen as a parent (script 71).</summary>
    public bool IsUsed { get; init; }

    /// <summary>
    /// (91) <see cref="IsUsed"/> is the sum of these two: used by stock or a document, and holding stock levels per
    /// warehouse - the picker says which ("has stock levels, cannot be a parent"), the delete what goes with it.
    /// </summary>
    public bool IsUsedInTransactions { get; init; }

    public bool HasStockLevels { get; init; }

    /// <summary>
    /// (90) An "On the way" warehouse (goods of transfer orders between dispatch and receipt). Listed only when the
    /// lookup is asked for them (includeTransit, Stock Valuation's filter) or when it is the includeId.
    /// </summary>
    public bool IsTransit { get; init; }

    /// <summary>
    /// (92) The caller may move stock in this warehouse (post, cancel, receive, dispatch, set its stock levels): worked
    /// out for the reader at each request, so a change of their warehouses shows at once. False on an On the way
    /// warehouse; true everywhere else for a reader with All warehouses. Pickers of documents that move stock offer only
    /// these; viewing is never limited.
    /// </summary>
    public bool CanUse { get; init; } = true;
}
