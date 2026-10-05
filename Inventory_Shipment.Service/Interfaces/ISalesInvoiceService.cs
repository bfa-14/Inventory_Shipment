using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
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

    /// <summary>
    /// One invoice. WITHOUT sales.profit.view IN <paramref name="permissions"/>, every cost and
    /// margin comes back null: a price is everybody's business, a margin is not. Null permissions
    /// means an internal caller that is not answering a request, and nothing is stripped.
    /// </summary>
    Task<Result<SalesInvoiceDto>> GetAsync(
        int id, IReadOnlySet<string>? permissions = null, CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates a draft (<paramref name="id"/> null) or replaces one.
    ///
    /// The caller's permission set decides <c>AllowPriceOverride</c>; the configuration decides
    /// <c>MaxDiscountPercent</c>. Neither is a request field, because neither is the caller's to choose.
    /// </summary>
    Task<Result<SalesInvoiceDto>> SaveDraftAsync(
        int? id, SaveSalesInvoiceRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <param name="acknowledgeOutOfStock">The user saw the out-of-stock warning and chose to proceed. Without it a shortage the policy allows is refused with OUT_OF_STOCK_CONFIRM.</param>
    Task<Result<SalesInvoiceDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string>? permissions = null,
        CancellationToken cancellationToken = default, bool acknowledgeOutOfStock = false);

    /// <summary>What posting this invoice would run into: the shortages and what the policy says of each. Needs the post permission.</summary>
    Task<Result<StockCheckDto>> StockCheckAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>A sales return draft from a posted invoice, at its prices and its original COGS. Needs sales.invoices.create.</summary>
    Task<Result<SalesInvoiceDto>> CreateReturnAsync(
        int id, DateOnly? documentDate, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// The Import Sales page's one call: the header and lines become a draft that is posted at once,
    /// and the answer is the posted invoice's summary.
    ///
    /// A DRAFT THAT FAILS TO POST IS DELETED before the error goes back. The page never showed a
    /// draft and has no screen to find one on; leaving it behind would be an invoice nobody can see
    /// holding a place in nobody's list. The error itself is the posting procedure's, unchanged —
    /// INSUFFICIENT_STOCK with its own figures, NO_PRICE with its "Line N:".
    ///
    /// TWO PERMISSIONS FOR ONE CALL. The action is guarded by sales.invoices.post; creating the
    /// invoice is a separate right, checked here, and a caller without it is refused (Forbidden)
    /// before anything is written.
    /// </summary>
    Task<Result<ImportPostResult>> ImportPostAsync(
        SaveSalesInvoiceRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<SalesInvoiceDto>> CancelAsync(
        int id, CancelSalesInvoiceRequest request, int userId, IReadOnlySet<string>? permissions = null,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posts each id in its own call; one refusal does not stop the others. Results keep the input order.</summary>
    Task<BulkActionResult> BulkPostAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Deletes each draft in its own call; a posted invoice among the ids is a NOT_DRAFT failure for that id alone.</summary>
    Task<BulkActionResult> BulkDeleteAsync(IReadOnlyList<int> ids, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// ONE invoice holding every imported line, each in the warehouse it names; posted at once when asked. The
    /// caller needs sales.invoices.create, and sales.invoices.post as well when posting.
    /// </summary>
    Task<Result<ImportCreateResult>> ImportCreateAsync(
        ImportCreateSalesInvoicesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The specifications already used for an item on sales lines, newest first.</summary>
    Task<Result<IReadOnlyList<string>>> ItemSpecificationsAsync(int itemId, CancellationToken cancellationToken = default);

    /// <summary>The rate the page pre-fills. Rate is null when none is defined — a warning, not an error.</summary>
    Task<Result<RateResolutionDto>> ResolveRateAsync(
        int priceListId, byte rateType, DateOnly? asOfDate, int? currencyId = null, CancellationToken cancellationToken = default);

    /// <summary>The invoice as a workbook: header incl. client, currency and rate; the lines; totals in both currencies.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default);

    Task<Result<SalesDocumentFileContent>> GetFileAsync(int id, int fileId, CancellationToken cancellationToken = default);

    /// <summary>Renames an attachment and, when content is given, replaces its bytes.</summary>
    Task<Result> UpdateFileAsync(
        int id, int fileId, string fileName, string? contentType, byte[]? content, int userId,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(int id, int fileId, int userId, CancellationToken cancellationToken = default);
}
