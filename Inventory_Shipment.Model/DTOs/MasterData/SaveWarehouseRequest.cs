using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a warehouse.</summary>
public sealed class SaveWarehouseRequest
{
    [Required]
    [StringLength(20, MinimumLength = 1)]
    public string WarehouseCode { get; init; } = string.Empty;

    [Required]
    [StringLength(150, MinimumLength = 1)]
    public string WarehouseName { get; init; } = string.Empty;

    /// <summary>The branch / site the warehouse belongs to. It must exist and be active.</summary>
    [Required]
    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    [StringLength(500)]
    public string? Address { get; init; }

    /// <summary>
    /// The warehouse this one stands under; null makes it a root.
    ///
    /// It need not share the branch - the tree and the branch answer different questions. The
    /// procedure refuses a parent that already stands under this warehouse, which is the one way a
    /// tree can be tied in a knot.
    /// </summary>
    [Range(1, int.MaxValue)]
    public int? ParentId { get; init; }

    public bool IsMainWarehouse { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>True allows selling out-of-stock items from this warehouse, false refuses, null follows the global setting.</summary>
    public bool? AllowOutOfStockOverride { get; init; }

    /// <summary>
    /// Set to true to confirm taking the Main Warehouse flag away from the warehouse that holds it.
    /// Without it the request fails with MAIN_WAREHOUSE_EXISTS so the user can be asked first.
    /// </summary>
    public bool ReplaceMainWarehouse { get; init; }

    /// <summary>Base64 ROWVERSION read with the warehouse (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}

public sealed class SetWarehouseStatusRequest
{
    public bool IsActive { get; init; }
}

/// <summary>Filters, sorting and paging for the warehouses list (bound from the query string).</summary>
public sealed class WarehouseQuery
{
    /// <summary>Matches Warehouse Code or Warehouse Name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Null = warehouses of every branch.</summary>
    public int? BranchId { get; init; }

    /// <summary>Null = both active and inactive warehouses.</summary>
    public bool? IsActive { get; init; }

    /// <summary>Null = main and non-main warehouses.</summary>
    public bool? IsMainWarehouse { get; init; }

    /// <summary>WarehouseCode | WarehouseName | BranchName | Address | IsMainWarehouse | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "WarehouseCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
