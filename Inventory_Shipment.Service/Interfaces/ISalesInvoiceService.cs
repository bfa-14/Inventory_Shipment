using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Sales invoices: the second document family, on the same skeleton as Inventory In / Out.
///
/// ONE TYPE, SO THE PERMISSIONS ARE THE CONTROLLER'S. Unlike the stock documents, where one
/// controller serves two kinds and the permission depends on the document's type, every invoice is
/// SINV and [HasPermission] on each action is the right tool. What this service still decides from
/// the caller's permissions is the ONE thing that changes a document's contents: whether a manual
/// price on a line is honoured (sales.invoices.priceoverride).
/// </summary>
public interface ISalesInvoiceService
{
    Task<Result<PagedResult<SalesInvoiceListDto>>> SearchAsync(
        SalesInvoiceQuery query, CancellationToken cancellationToken = default);

    Task<Result<SalesInvoiceDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates a draft (<paramref name="id"/> null) or replaces one.
    ///
    /// The caller's permission set decides <c>AllowPriceOverride</c>; the configuration decides
    /// <c>MaxDiscountPercent</c>. Neither is a request field, because neither is the caller's to choose.
    /// </summary>
    Task<Result<SalesInvoiceDto>> SaveDraftAsync(
        int? id, SaveSalesInvoiceRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<SalesInvoiceDto>> PostAsync(int id, string? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task<Result<SalesInvoiceDto>> CancelAsync(
        int id, CancelSalesInvoiceRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>The rate the page pre-fills. Rate is null when none is defined — a warning, not an error.</summary>
    Task<Result<RateResolutionDto>> ResolveRateAsync(
        int priceListId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    /// <summary>The invoice as a workbook: header incl. client, currency and rate; the lines; totals in both currencies.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default);

    Task<Result<SalesDocumentFileContent>> GetFileAsync(int id, int fileId, CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(int id, int fileId, int userId, CancellationToken cancellationToken = default);
}
