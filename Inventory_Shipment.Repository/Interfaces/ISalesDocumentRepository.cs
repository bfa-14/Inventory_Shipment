using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// The Sales document family — the invoice today, the order and the return later — and the rate
/// lookup the invoice page needs before an invoice exists.
///
/// EVERY RULE IS THE PROCEDURES'. Which price a line gets, whether the discount is allowed, whether
/// there is stock to invoice, what the rate is: all decided in SQL, in one transaction with the write
/// it guards. This layer carries parameters in and result sets out, exactly as the stock documents do.
/// </summary>
public interface ISalesDocumentRepository
{
    Task<(IReadOnlyList<SalesInvoiceListDto> Items, int TotalCount)> SearchAsync(
        SalesInvoiceQuery query, CancellationToken cancellationToken = default);

    /// <summary>Header, lines, files and audit in one round trip. Null when there is no such document.</summary>
    Task<SalesInvoiceDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates or replaces a draft and returns its id.
    ///
    /// <paramref name="allowPriceOverride"/> is what decides whether a manual price on a line is kept:
    /// it is the caller's PERMISSION, resolved by the service from the token, never a request field.
    /// </summary>
    Task<int> SaveAsync(
        SaveSalesInvoiceRequest request, int? id, bool allowPriceOverride, decimal maxDiscountPercent,
        int userId, CancellationToken cancellationToken = default);

    /// <summary>Writes the ledger, snapshots the cost of goods, assigns the number, closes the document.</summary>
    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>sales.usp_SalesDocument_CreateFromSource — a return draft from a posted invoice; the new id.</summary>
    Task<int> CreateFromSourceAsync(
        int sourceId, DateOnly? documentDate, int userId, CancellationToken cancellationToken = default);

    /// <summary>The rate for a price list's currency on a date. Null when the price list does not exist; Rate null when no rate is defined.</summary>
    /// <summary>sales.usp_SalesDocument_ItemSpecifications - what other invoices called this item.</summary>
    Task<IReadOnlyList<string>> ItemSpecificationsAsync(int itemId, CancellationToken cancellationToken = default);

    Task<RateResolutionDto?> ResolveRateAsync(
        int priceListId, byte rateType, DateOnly? asOfDate, int? currencyId = null, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int documentId, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default);

    Task<SalesDocumentFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default);
}

/// <summary>An attachment and its bytes — the only shape that carries content.</summary>
public sealed class SalesDocumentFileContent
{
    public int Id { get; init; }
    public int DocumentId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
