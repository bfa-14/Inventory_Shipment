namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A unit of measure an item can be packed in (table masterdata.UnitTypes) - PC, Box, Pallet,
/// Container... The list is editable master data: item units point at it, so a referenced unit
/// type can be deactivated but not deleted.
/// </summary>
public class UnitType
{
    public int Id { get; set; }
    public string UnitTypeName { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>One row of masterdata.usp_UnitType_Lookup - just enough to fill a Unit Type dropdown.</summary>
public sealed class UnitTypeLookup
{
    public int Id { get; set; }
    public string UnitTypeName { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
