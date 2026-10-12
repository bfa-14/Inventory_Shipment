using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Goods receipts over the procedures of script 64 (purchase.usp_GoodsReceipt_*). Business refusals arrive as
/// <see cref="Exceptions.BusinessRuleException"/> with the procedure's number (63xxx) and sentence.
/// </summary>
public interface IGoodsReceiptRepository
{
    Task<(IReadOnlyList<GoodsReceiptListItemDto> Items, int TotalCount, GoodsReceiptListTotalsDto Totals)> SearchAsync(
        GoodsReceiptQuery query, CancellationToken cancellationToken = default);

    Task<GoodsReceiptWaitingDto> WaitingCountAsync(int userId, CancellationToken cancellationToken = default);

    /// <summary>When goods receipts started (purchase.GoodsReceiptSwitch); null before the switch.</summary>
    Task<GoodsReceiptSwitchDto> SwitchAsync(CancellationToken cancellationToken = default);

    /// <summary>The receipt with its lines, matches, cost changes, files and audit; null when the id is unknown.</summary>
    Task<GoodsReceiptDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Status and number only (the after-the-fact reads of post-many and the from-* answers).</summary>
    Task<GoodsReceiptStub?> GetStubAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates a draft; returns its id. The lines go as they are given.</summary>
    Task<int> SaveAsync(
        int? id, GoodsReceiptSaveRequest request, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, int userId,
        CancellationToken cancellationToken = default);

    Task DeleteAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posts a draft; returns the number it was given.</summary>
    Task<string?> PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>A draft from a purchase order (purchase.usp_GoodsReceipt_CreateFromOrder); no lines = everything to receive.</summary>
    Task<int> CreateFromOrderAsync(
        int purchaseOrderId, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, DateOnly? documentDate,
        string? supplierReference, int? warehouseId, string? notes, int userId, CancellationToken cancellationToken = default);

    /// <summary>A draft from a posted invoice (purchase.usp_GoodsReceipt_CreateFromInvoice); no lines = everything to receive.</summary>
    Task<int> CreateFromInvoiceAsync(
        int invoiceId, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, DateOnly? documentDate,
        string? supplierReference, int? warehouseId, string? notes, int userId, CancellationToken cancellationToken = default);

    /// <summary>A container's draft (purchase.usp_GoodsReceipt_CreateForContainer, not silent); no lines = as loaded.</summary>
    Task<int> CreateForContainerAsync(
        int containerId, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, DateOnly? documentDate, int? warehouseId,
        int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// The item and the item's base unit of order or invoice lines (purchase.PurchaseDocumentLines), or of container
    /// lines: what a line given in pieces is sent as. Unknown ids are left out.
    /// </summary>
    Task<IReadOnlyDictionary<int, LineItemUnit>> LineItemUnitsAsync(
        ReceivableLineTable table, IReadOnlyCollection<int> lineIds, CancellationToken cancellationToken = default);

    /// <summary>The order lines (one order, or the supplier's posted / closed orders with something to receive).</summary>
    Task<ReceivableDto> OrderReceivableAsync(
        int? purchaseOrderId, int? supplierId, CancellationToken cancellationToken = default);

    /// <summary>The invoice's lines not linked to a container; null when it is not a purchase invoice.</summary>
    Task<ReceivableDto?> InvoiceReceivableAsync(int invoiceId, CancellationToken cancellationToken = default);

    /// <summary>The container and its lines; null when it does not exist.</summary>
    Task<ReceivableDto?> ContainerReceivableAsync(int containerId, CancellationToken cancellationToken = default);

    /// <summary>The containers that can be received now: status 2–5 and no draft or posted receipt.</summary>
    Task<IReadOnlyList<ReceivableContainerDto>> ReceivableContainersAsync(
        ReceivableContainersQuery query, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int goodsReceiptId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int goodsReceiptId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default);

    Task<DocumentFileDto?> UpdateFileAsync(int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default);

    Task<GoodsReceiptFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default);
}

/// <summary>A receipt's status and number.</summary>
public sealed class GoodsReceiptStub
{
    public int Id { get; init; }
    public byte Status { get; init; }
    public string? DocumentNumber { get; init; }
}

/// <summary>Which table the line ids of <see cref="IGoodsReceiptRepository.LineItemUnitsAsync"/> belong to.</summary>
public enum ReceivableLineTable
{
    /// <summary>purchase.PurchaseDocumentLines: an order line or an invoice line.</summary>
    PurchaseDocumentLine,

    /// <summary>logistics.ContainerLines.</summary>
    ContainerLine,
}

/// <summary>A line's item and the item's base unit.</summary>
public sealed class LineItemUnit
{
    public int LineId { get; init; }
    public int ItemId { get; init; }
    public int? BaseUnitId { get; init; }
}

/// <summary>One stored file with its bytes (the download).</summary>
public sealed class GoodsReceiptFileContent
{
    public int Id { get; init; }

    /// <summary>The goods receipt it belongs to.</summary>
    public int DocumentId { get; init; }

    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
