using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Interfaces;

public interface IItemService
{
    Task<Result<PagedResult<ItemListDto>>> SearchAsync(ItemQuery query, CancellationToken cancellationToken = default);

    /// <summary>The item with its units and file metadata.</summary>
    Task<Result<ItemDetailsDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The item's stock per warehouse, with totals. 404 when the item does not exist.</summary>
    Task<Result<ItemStockBalanceDto>> GetStockBalanceAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<ItemDetailsDto>> CreateAsync(SaveItemRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<ItemDetailsDto>> UpdateAsync(int id, SaveItemRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// Items for a dropdown; <paramref name="includeId"/> keeps one inactive item visible, and
    /// <paramref name="salesOnly"/> keeps only those with a unit that may be sold.
    /// </summary>
    Task<Result<IReadOnlyList<ItemLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, bool salesOnly = false, CancellationToken cancellationToken = default);

    /// <summary>Adds a unit and returns the item's refreshed unit list.</summary>
    Task<Result<IReadOnlyList<ItemUnitDto>>> AddUnitAsync(
        int itemId, SaveItemUnitRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Edits a unit and returns the item's refreshed unit list.</summary>
    Task<Result<IReadOnlyList<ItemUnitDto>>> UpdateUnitAsync(
        int itemId, int unitId, SaveItemUnitRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteUnitAsync(int itemId, int unitId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Stores an uploaded file against the item. <paramref name="isItemImage"/> replaces the item's
    /// current image; the service enforces the size cap and the content-type allow-list.
    /// </summary>
    Task<Result<ItemFileDto>> AddFileAsync(
        int itemId, ItemFileUpload upload, bool isItemImage, int userId, CancellationToken cancellationToken = default);

    /// <summary>The file with its bytes, for download. Fails with NOT_FOUND when it belongs to another item.</summary>
    Task<Result<ItemFile>> GetFileAsync(int itemId, int fileId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Renames one of the item's files and, when <paramref name="upload"/> is given, replaces its bytes
    /// under the same checks as an upload. Without one the stored file is kept.
    /// </summary>
    Task<Result> UpdateFileAsync(
        int itemId, int fileId, string? fileName, ItemFileUpload? upload, CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(int itemId, int fileId, CancellationToken cancellationToken = default);
}
