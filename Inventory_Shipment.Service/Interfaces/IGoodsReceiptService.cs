using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Goods receipts (scripts 64 and 65): the only way goods enter stock. Each call checks the caller's
/// purchase.goodsreceipts.* permission (the controller checks it too) and answers the procedures' refusals as they come.
/// </summary>
public interface IGoodsReceiptService
{
    Task<Result<GoodsReceiptListResult>> SearchAsync(
        GoodsReceiptQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The drafts, for the menu count.</summary>
    Task<Result<GoodsReceiptWaitingDto>> WaitingAsync(
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>When goods receipts started: the date of the purchase invoice list's banner (no permission: a date).</summary>
    Task<GoodsReceiptSwitchDto> SwitchAsync(CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptDto>> GetAsync(int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or saves a draft, of any source.</summary>
    Task<Result<GoodsReceiptDto>> SaveDraftAsync(
        int? id, GoodsReceiptSaveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Each draft posted on its own, in order: a refusal is that receipt's answer, the next one is still tried.</summary>
    Task<Result<IReadOnlyList<BulkActionItemResult>>> PostManyAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptDto>> CancelAsync(
        int id, GoodsReceiptCancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>What "Receive goods..." proposes: an order, an invoice, a supplier's orders, or a container.</summary>
    Task<Result<ReceivableDto>> ReceivableAsync(
        ReceivableQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The containers "+ New › From a container..." offers: status 2–5 with no receipt.</summary>
    Task<Result<IReadOnlyList<ReceivableContainerDto>>> ReceivableContainersAsync(
        ReceivableContainersQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptCreatedDto>> ReceiveFromOrderAsync(
        ReceiveFromOrderRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptCreatedDto>> ReceiveFromInvoiceAsync(
        ReceiveFromInvoiceRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptCreatedDto>> ReceiveContainerAsync(
        ReceiveContainerRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>GRN-{number}.xlsx: the header and the lines (expected, received, difference, reason, cost, value, source).</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int id, int? attachmentTypeId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<GoodsReceiptFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<DocumentFileDto>> UpdateFileAsync(
        int id, int fileId, DocumentFileEdit edit, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
