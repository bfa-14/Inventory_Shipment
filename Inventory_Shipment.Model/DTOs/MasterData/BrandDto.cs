namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Public view of a brand.</summary>
public sealed class BrandDto
{
    public int Id { get; init; }
    public string BrandCode { get; init; } = string.Empty;
    public string BrandName { get; init; } = string.Empty;
    public string? Description { get; init; }
    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>A brand as it appears in a dropdown.</summary>
public sealed class BrandLookupDto
{
    public int Id { get; init; }
    public string BrandCode { get; init; } = string.Empty;
    public string BrandName { get; init; } = string.Empty;
    public bool IsActive { get; init; }
}
