namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A product brand (table masterdata.Brands). A flat lookup - no hierarchy and no "main" brand;
/// items reference it through the Brand dropdown.
/// </summary>
public class Brand
{
    public int Id { get; set; }
    public string BrandCode { get; set; } = string.Empty;
    public string BrandName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>One row of masterdata.usp_Brand_Lookup - just enough to fill a Brand dropdown.</summary>
public sealed class BrandLookup
{
    public int Id { get; set; }
    public string BrandCode { get; set; } = string.Empty;
    public string BrandName { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
