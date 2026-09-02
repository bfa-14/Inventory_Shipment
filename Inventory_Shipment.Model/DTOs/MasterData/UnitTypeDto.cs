namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Public view of a unit type.</summary>
public sealed class UnitTypeDto
{
    public int Id { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>A unit type as it appears in a dropdown.</summary>
public sealed class UnitTypeLookupDto
{
    public int Id { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public bool IsActive { get; init; }
}
