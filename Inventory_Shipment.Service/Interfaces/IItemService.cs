using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
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

    /// <summary>The containers carrying the item, and what is still on the way. 404 for an unknown item.</summary>
    Task<Result<ItemContainersDto>> GetContainersAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The purchase orders with the item on them, and what is still on order. 404 for an unknown item.</summary>
    Task<Result<ItemPurchaseOrdersDto>> GetPurchaseOrdersAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The item's stock statement across every warehouse, optionally for a date range. 404 for an unknown item.</summary>
    Task<Result<ItemStockStatementDto>> GetStockStatementAsync(
        int id, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default);

    Task<Result<ItemDetailsDto>> CreateAsync(SaveItemRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<ItemDetailsDto>> UpdateAsync(int id, SaveItemRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Items for a dropdown; <paramref name="includeId"/> keeps one inactive item visible,
    /// <paramref name="salesOnly"/> keeps only those with a unit that may be sold, and
    /// <paramref name="bivacOnly"/> only those with "BIVAC Item" ticked. <paramref name="search"/> and
    /// <paramref name="top"/>, when given, narrow and cap the list; otherwise the procedure's defaults apply.
    /// </summary>
    Task<Result<IReadOnlyList<ItemLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, bool salesOnly = false, bool bivacOnly = false,
        string? search = null, int? top = null, CancellationToken cancellationToken = default);

    /// <summary>Adds a unit and returns the item's refreshed unit list.</summary>
    Task<Result<IReadOnlyList<ItemUnitDto>>> AddUnitAsync(
        int itemId, SaveItemUnitRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Edits a unit and returns the item's refreshed unit list.</summary>
    Task<Result<IReadOnlyList<ItemUnitDto>>> UpdateUnitAsync(
        int itemId, int unitId, SaveItemUnitRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteUnitAsync(int itemId, int unitId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Stores the item's picture (a JPEG, PNG or WebP of up to 5 MB, no type), replacing the current one. The
    /// picture is not a document: it is shown on the item and never listed with its documents.
    /// </summary>
    Task<Result<ItemFileDto>> AddImageAsync(
        int itemId, ItemFileUpload upload, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Attaches a document to the item (script 67, kind ITEM): the shared checks of every attachment (20 MB, the
    /// shared extensions, a type) are the controller's; the procedure checks the type is active and used for items
    /// (56009). Answers the new file's id.
    /// </summary>
    Task<Result<int>> AddDocumentFileAsync(
        int itemId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>The item's documents with their type, date and note, newest first (never the picture); attachmentTypeId = one type only.</summary>
    Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int itemId, int? attachmentTypeId, CancellationToken cancellationToken = default);

    /// <summary>The file with its bytes, for download (a document or the picture). Fails with NOT_FOUND when it belongs to another item.</summary>
    Task<Result<ItemFile>> GetFileAsync(int itemId, int fileId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Edits one of the item's documents: its name, its type / date / note and, when the edit carries one, a new
    /// version of the file in the same place in the list. The picture is not edited here (NOT_FOUND): a new picture
    /// is uploaded instead. Answers the file's row.
    /// </summary>
    Task<Result<DocumentFileDto>> UpdateFileAsync(
        int itemId, int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default);

    /// <summary>Deletes one of the item's files: a document or the picture.</summary>
    Task<Result> DeleteFileAsync(int itemId, int fileId, CancellationToken cancellationToken = default);
}
