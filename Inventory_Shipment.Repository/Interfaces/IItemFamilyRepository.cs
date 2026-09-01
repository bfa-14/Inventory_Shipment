using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.ItemFamilies through its stored procedures. Every method turns a business-rule THROW
/// (54000-54008) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IItemFamilyRepository
{
    /// <summary>
    /// masterdata.usp_ItemFamily_Tree - every family as a flat list, each with its direct child count.
    /// There is no paging on purpose: paging cannot work on a tree, and the client nests the rows itself.
    /// </summary>
    Task<IReadOnlyList<ItemFamily>> TreeAsync(CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_ItemFamily_Get.</summary>
    Task<ItemFamily?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_ItemFamily_Lookup - the families a dropdown offers, ordered by level then code.
    /// <paramref name="includeId"/> keeps one extra family in the list even when it is inactive, so an
    /// edit form can still show the family the record currently points at.
    /// </summary>
    Task<IReadOnlyList<ItemFamilyLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_ItemFamily_NextChildCode - the code suggested for a new child of
    /// <paramref name="parentId"/> (FAM-### for a root, &lt;parent&gt;-## below one). Throws 54006 when
    /// the parent does not exist.
    /// </summary>
    Task<string> NextChildCodeAsync(int? parentId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_ItemFamily_Create - returns the new id. Throws 54000 / 54001 / 54002 / 54006 / 54008.</summary>
    Task<int> CreateAsync(ItemFamily family, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_ItemFamily_Update - throws 54000 / 54001 / 54002 / 54004 / 54006 / 54007 / 54008.
    /// A move re-levels the whole subtree and deactivating cascades down it.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(
        ItemFamily family, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_ItemFamily_SetActive - deactivating cascades to the subtree; activating touches
    /// only this family. Throws 54006 / 54008.
    /// </summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_ItemFamily_Delete - throws 54003 (referenced) / 54005 (has children) / 54006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);
}
