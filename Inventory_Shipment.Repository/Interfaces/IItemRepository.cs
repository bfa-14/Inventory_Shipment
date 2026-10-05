using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// inventory.Items with its units and files, through stored procedures. Every method turns a
/// business-rule THROW (56000-56008) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IItemRepository
{
    /// <summary>inventory.usp_Item_Search - one page of items plus the total row count.</summary>
    Task<(IReadOnlyList<Item> Items, int TotalCount)> SearchAsync(
        ItemQuery query, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_Get - the item, its units and its file metadata in one round trip
    /// (three result sets). Null when the item does not exist.
    /// </summary>
    Task<(Item Item, IReadOnlyList<ItemUnit> Units, IReadOnlyList<ItemFile> Files)?> GetAsync(
        int id, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_Item_StockBalance - the item's on hand per warehouse that has held it.</summary>
    Task<IReadOnlyList<ItemStockBalanceRowDto>> GetStockBalanceAsync(int itemId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_Item_Create - returns the new id. Throws 56000 / 56001 / 56008.</summary>
    Task<int> CreateAsync(Item item, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_Update - throws 56000 / 56001 / 56004 / 56006 / 56008.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(Item item, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_SetPurchasing - the default supplier and lead time, written after create /
    /// update in the same service call. No row-version check: the item was just saved by this caller.
    /// Throws 56000 when the supplier is missing, inactive or not a supplier.
    /// </summary>
    Task SetPurchasingAsync(
        int id, int? defaultSupplierId, int? leadTimeDays, int? pcPerContainer, decimal? weightKg,
        decimal? volumeCbm, int? userId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_Item_SetActive - throws 56006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_Delete - removes the item with its units and files.
    /// Throws 56003 when anything else references the item or one of its units, 56006 when it is gone.
    /// </summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_Lookup - the items an Item picker offers, each with the SKU of its base unit.
    /// <paramref name="includeId"/> keeps one extra item in the list even when it is inactive.
    /// <paramref name="salesOnly"/> keeps only the items with a unit that may be sold, and reports
    /// that unit rather than the base one — for the sales invoice, which cannot sell the others.
    /// </summary>
    Task<IReadOnlyList<ItemLookup>> LookupAsync(
        bool activeOnly, int? includeId, bool salesOnly = false, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemUnit_Create - returns the new id. Throws 56000 / 56002 / 56005 / 56006 /
    /// 56007 / 56008. The first unit of an item must be the base unit.
    /// </summary>
    Task<int> CreateUnitAsync(ItemUnit unit, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemUnit_Update - throws 56000 / 56002 / 56004 / 56005 / 56006 / 56007 / 56008.
    /// Setting IsBaseUnit demotes the unit that is currently the base.
    /// </summary>
    Task UpdateUnitAsync(ItemUnit unit, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemUnit_Delete - throws 56003 (referenced by transactions),
    /// 56005 (the base unit cannot be deleted) or 56006.
    /// </summary>
    Task DeleteUnitAsync(int unitId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemFile_Add - stores the bytes and returns the new id. Adding an item image
    /// replaces the one the item already has. Throws 56000 / 56006.
    /// </summary>
    Task<int> AddFileAsync(ItemFile file, int? userId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_ItemFile_Get - metadata plus the bytes, for download. Null when it is gone.</summary>
    Task<ItemFile?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemFile_Update - renames the file and, when content is given, replaces its bytes.
    /// Throws 56000 / 56006.
    /// </summary>
    Task UpdateFileAsync(
        int fileId, string fileName, string? contentType, byte[]? content, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_ItemFile_Delete - throws 56006.</summary>
    Task DeleteFileAsync(int fileId, CancellationToken cancellationToken = default);
}
