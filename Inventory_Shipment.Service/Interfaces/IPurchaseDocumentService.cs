using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Purchase orders, purchase invoices and purchase returns: one engine, three permission sets.
///
/// EVERY METHOD TAKES THE CALLER'S PERMISSIONS because the permission an action needs depends on
/// the kind of the document, which is only known once it is read. The controller authenticates;
/// the service decides which of purchase.orders.* / purchase.invoices.* / purchase.returns.* applies.
/// </summary>
public interface IPurchaseDocumentService
{
    Task<Result<PagedResult<PurchaseDocumentListDto>>> SearchAsync(
        PurchaseDocumentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PurchaseDocumentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PurchaseDocumentDto>> SaveDraftAsync(
        int? id, SavePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<PurchaseDocumentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<PurchaseDocumentDto>> CancelAsync(
        int id, CancelPurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Orders only: ends an open order that will not be received any further.</summary>
    Task<Result<PurchaseDocumentDto>> CloseAsync(
        int id, ClosePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Records what the supplier has shipped on an open order. Needs purchase.orders.create.</summary>
    Task<Result<PurchaseDocumentDto>> MarkShippedAsync(
        int id, MarkShippedRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Replaces the charges of a draft purchase invoice. Needs purchase.invoices.create.</summary>
    Task<Result<PurchaseDocumentDto>> SetChargesAsync(
        int id, SetPurchaseChargesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// A draft of <paramref name="targetTypeCode"/> holding what remains on the source: an invoice
    /// from an order, a return from an invoice. The caller needs the create permission of the TARGET.
    /// </summary>
    Task<Result<PurchaseDocumentDto>> CreateFromSourceAsync(
        int sourceId, string targetTypeCode, CreateFromSourceRequest request, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<BulkActionResult> BulkPostAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<BulkActionResult> BulkDeleteAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ImportCreateResult>> ImportCreateAsync(
        ImportCreatePurchaseDocumentsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<PurchaseRateResolutionDto>> ResolveRateAsync(
        int currencyId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<PurchaseDocumentFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
