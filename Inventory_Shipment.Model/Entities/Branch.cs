namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A company branch / site (table masterdata.Branches). Exactly one active branch carries
/// <see cref="IsMainBranch"/>; warehouses, inventory locations and transactions reference it later.
/// </summary>
public class Branch
{
    public int Id { get; set; }
    public string BranchCode { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? Address { get; set; }
    public bool IsMainBranch { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}
