namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A warehouse (table masterdata.Warehouses). Every warehouse belongs to a branch / site; exactly one
/// active warehouse carries <see cref="IsMainWarehouse"/>. Inventory is later tracked per warehouse.
/// </summary>
public class Warehouse
{
    public int Id { get; set; }
    public string WarehouseCode { get; set; } = string.Empty;
    public string WarehouseName { get; set; } = string.Empty;
    public int BranchId { get; set; }

    /// <summary>Code of the owning branch. Read-only: it comes from the join, never from the caller.</summary>
    public string BranchCode { get; set; } = string.Empty;

    /// <summary>Name of the owning branch. Read-only: it comes from the join, never from the caller.</summary>
    public string BranchName { get; set; } = string.Empty;

    public string? Address { get; set; }

    /// <summary>The warehouse this one stands under; null for a root. It need not share the branch.</summary>
    public int? ParentId { get; set; }

    /// <summary>Code of the parent. Read-only: it comes from the join, never from the caller.</summary>
    public string? ParentCode { get; set; }

    /// <summary>Name of the parent. Read-only: it comes from the join, never from the caller.</summary>
    public string? ParentName { get; set; }

    /// <summary>Depth in the tree, 1 for a root. Maintained by the procedures, never sent in.</summary>
    public int Level { get; set; } = 1;

    /// <summary>Warehouses standing directly under this one; 0 means a leaf, which is where stock lives.</summary>
    public int ChildCount { get; set; }

    public bool IsMainWarehouse { get; set; }

    /// <summary>Out-of-stock sales: true allows, false disallows, null follows the global setting.</summary>
    public bool? AllowOutOfStockOverride { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>One row of masterdata.usp_Branch_Lookup - just enough to fill a Branch / Site dropdown.</summary>
public sealed class BranchLookup
{
    public int Id { get; set; }
    public string BranchCode { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public bool IsMainBranch { get; set; }
    public bool IsActive { get; set; }
}
