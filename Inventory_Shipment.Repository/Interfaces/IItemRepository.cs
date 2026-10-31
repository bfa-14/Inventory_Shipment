using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// inventory.Items with its units and files, through stored procedures. Every method turns a
/// business-rule THROW (56000-56009) into a <c>BusinessRuleException</c>.
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

    /// <summary>inventory.usp_Item_Containers - every container carrying the item, newest first.</summary>
    Task<IReadOnlyList<ItemContainerDto>> GetContainersAsync(int itemId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_Item_PurchaseOrders - every purchase order with the item on it, newest first.</summary>
    Task<IReadOnlyList<ItemPurchaseOrderDto>> GetPurchaseOrdersAsync(int itemId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_Item_StockStatement - the balance brought forward and the movements in the range.</summary>
    Task<(int OpeningBase, IReadOnlyList<ItemStockMovementDto> Movements)> GetStockStatementAsync(
        int itemId, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default);

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

    /// <summary>inventory.usp_Item_SetNotes (script 87) - the note and the link; throws 56000.</summary>
    Task SetNotesAsync(int id, string? note, string? link, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// (93) inventory.usp_Item_SetTracking - Tracking, Requires expiry date and Serial no. length, written after create /
    /// update like the note (only when one of them changes); throws 56000 (the rules) and 56006 (no such item).
    /// </summary>
    /// <summary>(98) inventory.usp_Item_SetLeadTime - the lead time in months (the days follow), after create / update.</summary>
    Task SetLeadTimeAsync(int id, decimal? leadTimeMonths, int? userId, CancellationToken cancellationToken = default);

    Task SetTrackingAsync(
        int id, Model.Enums.TrackingMode trackingMode, bool requiresExpiry, int? serialLength, int? userId,
        CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_Item_SetActive - throws 56006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_Delete - removes the item with its units and files (and its stock levels per warehouse, whose
    /// history records the removal by <paramref name="userId"/>, script 91).
    /// Throws 56003 when anything else references the item or one of its units, 56006 when it is gone.
    /// </summary>
    Task DeleteAsync(int id, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_Item_Lookup - the items an Item picker offers, each with the SKU of its base unit.
    /// <paramref name="includeId"/> keeps one extra item in the list even when it is inactive.
    /// <paramref name="salesOnly"/> keeps only the items with a unit that may be sold, and reports
    /// that unit rather than the base one — for the sales invoice, which cannot sell the others.
    /// <paramref name="bivacOnly"/> keeps only the items with "BIVAC Item" ticked (script 66), for the
    /// lines of a BIVAC Out. <paramref name="search"/> (code or name) and <paramref name="top"/> are
    /// passed only when given, so the procedure's own defaults apply otherwise.
    /// </summary>
    Task<IReadOnlyList<ItemLookup>> LookupAsync(
        bool activeOnly, int? includeId, bool salesOnly = false, bool bivacOnly = false,
        string? search = null, int? top = null, CancellationToken cancellationToken = default);

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
    /// replaces the one the item already has. <paramref name="fields"/> are the type / date / note of a
    /// document (script 67), null for the picture, which has none. Throws 56000 / 56006, and 56009 when the
    /// type of a document is missing, inactive or not used for items.
    /// </summary>
    Task<int> AddFileAsync(
        ItemFile file, DocumentFileFields? fields, int? userId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_ItemFile_Get - metadata plus the bytes, for download. Null when it is gone.</summary>
    Task<ItemFile?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemFile_List (script 67) - the item's documents with their type, date and note, newest
    /// first; never the picture. attachmentTypeId = one type only, fileId = that file only.
    /// </summary>
    Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int itemId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default);

    /// <summary>
    /// inventory.usp_ItemFile_Update - renames the file and, when content is given, replaces its bytes;
    /// <paramref name="fields"/> sets the type / date / note of a document (script 67), and the document's row is
    /// answered (null for the picture, which the list never shows). Throws 56000 / 56006 / 56009.
    /// </summary>
    Task<DocumentFileDto?> UpdateFileAsync(
        int fileId, string fileName, string? contentType, byte[]? content, DocumentFileFields? fields,
        CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_ItemFile_Delete - throws 56006.</summary>
    Task DeleteFileAsync(int fileId, CancellationToken cancellationToken = default);
}
