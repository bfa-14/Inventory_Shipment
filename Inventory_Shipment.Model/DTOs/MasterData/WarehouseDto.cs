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
}
