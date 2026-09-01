using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on an item family.</summary>
public sealed class SaveItemFamilyRequest
{
    /// <summary>
    /// Stable, globally unique code. GET next-code suggests one from the parent (FAM-002 -&gt; FAM-002-01),
    /// but the user may type any code; it is never rewritten when the family is moved.
    /// </summary>
    [Required]
    [StringLength(50, MinimumLength = 1)]
    public string FamilyCode { get; init; } = string.Empty;

    /// <summary>Must be unique among the families sharing the same parent.</summary>
    [Required]
    [StringLength(150, MinimumLength = 1)]
    public string FamilyName { get; init; } = string.Empty;

    /// <summary>The parent family; null creates (or moves the family to) a root.</summary>
    public int? ParentId { get; init; }

    [StringLength(500)]
    public string? Description { get; init; }

    /// <summary>A family can be active only while its parent is; turning it off cascades to the subtree.</summary>
    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the family (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
