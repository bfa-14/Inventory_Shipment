namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>
/// Public view of one node of the item family tree. The tree endpoint returns every family as a flat
/// list in this shape and the client nests them with <see cref="ParentId"/>.
/// </summary>
public sealed class ItemFamilyDto
{
    public int Id { get; init; }

    /// <summary>Null for a root family.</summary>
    public int? ParentId { get; init; }

    public string FamilyCode { get; init; } = string.Empty;
    public string FamilyName { get; init; } = string.Empty;
    public string? Description { get; init; }

    /// <summary>Depth in the tree, 1 for a root.</summary>
    public int Level { get; init; }

    public bool IsActive { get; init; }

    /// <summary>Number of direct children; 0 means the row is a leaf.</summary>
    public int ChildCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>An item family as it appears in a dropdown; the client indents the label by <see cref="Level"/>.</summary>
public sealed class ItemFamilyLookupDto
{
    public int Id { get; init; }
    public int? ParentId { get; init; }
    public string FamilyCode { get; init; } = string.Empty;
    public string FamilyName { get; init; } = string.Empty;
    public int Level { get; init; }
    public bool IsActive { get; init; }
}
