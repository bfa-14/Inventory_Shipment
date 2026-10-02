using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>The Purchase family (orders, invoices, returns) over the purchase.usp_PurchaseDocument_* procedures.</summary>
public interface IPurchaseDocumentRepository
{
    Task<(IReadOnlyList<PurchaseDocumentListDto> Items, int TotalCount)> SearchAsync(
        PurchaseDocumentQuery query, CancellationToken cancellationToken = default);

    Task<PurchaseDocumentDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The kind and status of a document, for the permission check that precedes every action on it.</summary>
    Task<PurchaseDocumentStub?> GetStubAsync(int id, CancellationToken cancellationToken = default);

    Task<int> SaveAsync(
        SavePurchaseDocumentRequest request, int? id, decimal maxDiscountPercent, int userId,
        CancellationToken cancellationToken = default);

    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CloseAsync(int id, string? reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>purchase.usp_PurchaseDocument_SetCharges — draft invoices only; throws 65012 when a charge is refused.</summary>
    Task SetChargesAsync(
        int id, SetPurchaseChargesRequest request, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>purchase.usp_PurchaseDocument_MarkShipped — open orders only; no lines means everything was shipped.</summary>
    Task MarkShippedAsync(
        int id, IReadOnlyList<ShippedLineRequest> lines, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// What remains on the source as drafts of the target kind: from an order ONE INVOICE PER ITEM (script 45, the
    /// references copied to each), from an invoice one return. The first id, and the rows of the invoices (none for a return).
    /// </summary>
    Task<CreatedFromSource> CreateFromSourceAsync(
        int sourceId, string targetTypeCode, DateOnly? documentDate, string? exporterReference, string? commercialInvoiceNo,
        int userId, CancellationToken cancellationToken = default);

    /// <summary>purchase.usp_PurchaseDocument_CreateFromContainers — draft invoices from container lines of one order, one per item.</summary>
    Task<IReadOnlyList<CreatedPurchaseInvoiceDto>> CreateFromContainersAsync(
        int purchaseOrderId, IReadOnlyList<ContainerLineQuantityRequest> lines, DateOnly? documentDate,
        string? exporterReference, string? commercialInvoiceNo, int userId, CancellationToken cancellationToken = default);

    /// <summary>purchase.usp_PurchaseDocument_SplitByItem — a draft invoice of several items into one per item; the original first.</summary>
    Task<IReadOnlyList<CreatedPurchaseInvoiceDto>> SplitByItemAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task<PurchaseRateResolutionDto?> ResolveRateAsync(
        int currencyId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int documentId, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default);

    Task<PurchaseDocumentFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default);
}

/// <summary>Just enough of a document to decide which permission an action on it needs.</summary>
public sealed class PurchaseDocumentStub
{
    public int Id { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public byte Status { get; init; }
    public string? DocumentNumber { get; init; }
}

public sealed class PurchaseDocumentFileContent
{
    public int Id { get; init; }
    public int DocumentId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
