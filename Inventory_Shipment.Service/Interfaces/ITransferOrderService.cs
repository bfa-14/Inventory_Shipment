using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Transfer orders (script 90): the order, its dispatches and receipts, its approval, its files, its import and export.
/// Each call checks the caller's permission (the controller's [HasPermission] is the first gate), strips the value
/// figures for a reader without <c>inventory.valuation.view</c>, and answers the procedures' refusals as they come.
/// </summary>
public interface ITransferOrderService
{
    Task<Result<TransferOrderListResult>> SearchAsync(
        TransferOrderQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The menu count of the approvers: 0 for a reader who may not approve.</summary>
    Task<Result<TransferWaitingDto>> WaitingAsync(
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<TransferAvailabilityDto>>> AvailabilityAsync(
        TransferAvailabilityQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<TransferOrderDto>> GetAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or replaces a draft; answers the order as saved.</summary>
    Task<Result<TransferOrderDto>> SaveAsync(
        int? id, SaveTransferOrderRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferOrderDto>> UpdateDetailsAsync(
        int id, UpdateTransferDetailsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> ReleaseAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> SendForApprovalAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Approve a waiting order, or Approve &amp; release a draft (when the TRO type asks for approval).</summary>
    Task<Result<TransferActionResult>> ApproveAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> RejectAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> WithdrawAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> BackToDraftAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferPostedResult>> DispatchAsync(
        int id, DispatchTransferRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferPostedResult>> ReceiveAsync(
        int id, ReceiveTransferRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Needs both the dispatch and the receive permission (FB decision 17).</summary>
    Task<Result<TransferPostedResult>> DispatchAndReceiveAsync(
        int id, DispatchTransferRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> NothingMoreSentAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> CancelAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> ReversePostingAsync(
        int id, int postingId, ReverseTransferPostingRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<TransferActionResult>> ChangeEtaAsync(
        int id, int postingId, ChangeTransferEtaRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>A new draft from To back to From; answers the new order.</summary>
    Task<Result<TransferOrderDto>> CreateReturnAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Transfer_Order_Lines_Template.xlsx.</summary>
    Result<(byte[] Content, string FileName)> ImportTemplate(IReadOnlySet<string> permissions);

    /// <summary>The lines of a file judged against the order's From (the sales import's rows and verdicts); nothing is saved.</summary>
    Task<Result<ImportValidationResult>> ValidateImportAsync(
        Stream file, string fileName, long fileLength, int? fromWarehouseId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int id, int? attachmentTypeId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<TransferOrderFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<DocumentFileDto>> UpdateFileAsync(
        int id, int fileId, DocumentFileEdit edit, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /* ── (91) Fill to Max, Add items below Min, a transfer order from Stock Levels ────────────── */

    /// <summary>The plan of Fill to Max (no addItems) or Add items below Min (addItems), computed on the server; nothing written.</summary>
    Task<Result<TransferFillResult>> FillToMaxPreviewAsync(
        int id, TransferFillRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The same plan computed again and written with the order's row version; answers the order re-read.</summary>
    Task<Result<TransferFillResult>> FillToMaxAsync(
        int id, TransferFillRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The drawer: every item with a level at the order's To, and the server's proposal per unit.</summary>
    Task<Result<TransferBelowMinResult>> BelowMinAsync(
        int id, TransferBelowMinQuery query, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>One draft from ticked rows of Inventory › Stock Levels (transfers.create AND stocklevels.view).</summary>
    Task<Result<CreateTransferFromLevelsResult>> CreateFromLevelsAsync(
        CreateTransferFromLevelsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
