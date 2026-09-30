using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Inventory In / Out documents.
///
/// THE PERMISSION CHECK LIVES HERE, NOT ON THE CONTROLLER, and that is the one departure from the
/// house pattern. One controller serves both document kinds, and which permission applies depends on
/// the document's TYPE — inventory.stockin.* or inventory.stockout.* — which for an existing document
/// is only known after reading it. [HasPermission] is evaluated before the action runs and cannot ask
/// that question, so the check is made where the answer exists, and returns Forbidden the same way.
/// </summary>
public interface IStockDocumentService
{
    Task<Result<IReadOnlyList<DocumentTypeDto>>> GetDocumentTypesAsync(CancellationToken cancellationToken = default);

    /// <summary>The configuration page's save: wording, numbering, pricing and behaviour of one document type.</summary>
    Task<Result<DocumentTypeDto>> UpdateDocumentTypeAsync(
        int id, UpdateDocumentTypeRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posts each id in its own call; one refusal does not stop the others. Results keep the input order.</summary>
    Task<BulkActionResult> BulkPostAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Deletes each draft in its own call; a posted document among the ids is a NOT_DRAFT failure for that id alone.</summary>
    Task<BulkActionResult> BulkDeleteAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>ONE document holding every imported line, each in the warehouse it names; posted at once when asked.</summary>
    Task<Result<ImportCreateResult>> ImportCreateAsync(
        ImportCreateStockDocumentsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<StockReasonDto>>> GetStockReasonsAsync(short? direction, CancellationToken cancellationToken = default);

    Task<Result<decimal>> GetOnHandAsync(int itemId, int warehouseId, CancellationToken cancellationToken = default);

    Task<Result<PagedResult<StockDocumentListDto>>> SearchAsync(
        StockDocumentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<StockDocumentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates a draft (<paramref name="id"/> null) or replaces one.</summary>
    Task<Result<StockDocumentDto>> SaveDraftAsync(
        int? id, SaveStockDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<StockDocumentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<StockDocumentDto>> CancelAsync(
        int id, CancelStockDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The document as a workbook: a header block, the lines, and the totals.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<Repository.Interfaces.StockDocumentFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
