namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A node of the item family tree (table masterdata.ItemFamilies). The tree is self-referencing with
/// UNLIMITED depth: <see cref="ParentId"/> is null for a root family, and items attach to a family at
/// any level. <see cref="FamilyCode"/> is stable - moving a family never renames it.
/// </summary>
public class ItemFamily
{
    public int Id { get; set; }

    /// <summary>The family this one sits under; null for a root family.</summary>
    public int? ParentId { get; set; }

    /// <summary>Globally unique, stable code (FAM-001, FAM-001-03-01...).</summary>
    public string FamilyCode { get; set; } = string.Empty;

    /// <summary>Unique among the siblings of the same parent.</summary>
    public string FamilyName { get; set; } = string.Empty;

    public string? Description { get; set; }

    /// <summary>Depth in the tree, 1 for a root. Maintained by the stored procedures on create and move.</summary>
    public int Level { get; set; } = 1;

    /// <summary>A family can be active only while its parent is; deactivating cascades down the subtree.</summary>
    public bool IsActive { get; set; } = true;

    /// <summary>Number of direct children, computed by the procedures - the tree grid shows a chevron when it is &gt; 0.</summary>
    public int ChildCount { get; set; }

    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>One row of masterdata.usp_ItemFamily_Lookup - just enough to fill an Item Family dropdown.</summary>
public sealed class ItemFamilyLookup
{
    public int Id { get; set; }
    public int? ParentId { get; set; }
    public string FamilyCode { get; set; } = string.Empty;
    public string FamilyName { get; set; } = string.Empty;
    public int Level { get; set; }
    public bool IsActive { get; set; }
}
