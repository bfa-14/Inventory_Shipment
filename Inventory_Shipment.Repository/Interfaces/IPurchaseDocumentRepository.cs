using Inventory_Shipment.Model.DTOs.Documents;
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

    /// <summary>
    /// purchase.usp_PurchaseDocument_Post. Since script 65 a supplier invoice moves no stock: it adjusts the cost of
    /// goods already received (the outcome's CostAdjusted*), and with <paramref name="receiveNow"/> its lines not in a
    /// container are then received with a goods receipt, created and posted in a second transaction - a receipt that
    /// fails leaves the invoice posted, with the reason in the outcome's ReceiveWarning.
    /// </summary>
    Task<PurchasePostOutcome> PostAsync(
        int id, byte[]? rowVersion, int userId, bool receiveNow = false, CancellationToken cancellationToken = default);

    /// <summary>
    /// purchase.usp_PurchaseInvoice_ReceiptCostPreview: what posting a DRAFT supplier invoice would do to the cost of the
    /// goods already received, per line (an estimate). No rows for a document that is not a draft; 65006 when it is not
    /// a supplier invoice.
    /// </summary>
    Task<IReadOnlyList<ReceiptCostPreviewLineDto>> ReceiptCostPreviewAsync(int invoiceId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

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
    /// references copied to each) or, with <paramref name="onePerItem"/> false, one invoice of every item (script 63;
    /// null = the setting); from an invoice one return. The first id, and the rows of the invoices (none for a return).
    /// </summary>
    Task<CreatedFromSource> CreateFromSourceAsync(
        int sourceId, string targetTypeCode, DateOnly? documentDate, string? exporterReference, string? commercialInvoiceNo,
        bool? onePerItem, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// purchase.usp_PurchaseDocument_CreateFromContainers — draft invoices from container lines of one order, one per
    /// item, or one of every item when <paramref name="onePerItem"/> is false (null = the setting).
    /// </summary>
    Task<IReadOnlyList<CreatedPurchaseInvoiceDto>> CreateFromContainersAsync(
        int purchaseOrderId, IReadOnlyList<ContainerLineQuantityRequest> lines, DateOnly? documentDate,
        string? exporterReference, string? commercialInvoiceNo, bool? onePerItem, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>The setting Purchase.OneItemPerInvoice (script 63): true = one item per supplier invoice.</summary>
    Task<bool> OneItemPerInvoiceAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// purchase.usp_PurchaseDocument_SplitByItem — a draft invoice of several items into one per item, each of one item
    /// from then on; the original first.
    /// </summary>
    Task<IReadOnlyList<CreatedPurchaseInvoiceDto>> SplitByItemAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task<PurchaseRateResolutionDto?> ResolveRateAsync(
        int currencyId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    /// <summary>The file with its type (required, used for the document's kind), date and note (script 52).</summary>
    Task<int> AddFileAsync(
        int documentId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>The files of a document with their type, date and note, newest first; one type, or one file, when asked.</summary>
    Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int documentId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default);

    /// <summary>
    /// The name, type, date and note of a file (the upload's checks) and, when content is given, its bytes; the file as
    /// it now stands.
    /// </summary>
    Task<DocumentFileDto?> UpdateFileAsync(
        int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default);

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

/// <summary>
/// What usp_PurchaseDocument_Post answered (script 65): the number, the cost adjustment of goods already received
/// (amount = to stock + to cost of sales; 0 when nothing moved), and the goods receipt of "Receive the goods now" - its id
/// and number when it was posted, else the warning saying why not (the invoice stays posted either way).
/// </summary>
public sealed class PurchasePostOutcome
{
    public string? DocumentNumber { get; init; }
    public decimal CostAdjustedBase { get; init; }
    public decimal CostAdjustedInventoryBase { get; init; }
    public decimal CostAdjustedCogsBase { get; init; }
    public int CostAdjustedLines { get; init; }
    public int? GoodsReceiptId { get; init; }
    public string? GoodsReceiptNumber { get; init; }
    public string? ReceiveWarning { get; init; }

    /// <summary>(79) The PINV type receives the goods when an invoice is posted ("Affects on-hand"), captured on it.</summary>
    public bool ReceiveOnPost { get; init; }
}

public sealed class PurchaseDocumentFileContent
{
    public int Id { get; init; }
    public int DocumentId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
