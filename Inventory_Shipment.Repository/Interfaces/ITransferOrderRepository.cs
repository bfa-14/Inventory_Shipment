using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Transfer orders over the procedures of script 90 (inventory.usp_TransferOrder_* and usp_TransferPosting_*). Business
/// refusals arrive as <see cref="Exceptions.BusinessRuleException"/> with the procedure's number (62xxx) and sentence,
/// the first row of inventory.fn_TransferOrder_Blocks for the action - the same sentence the page's disabled button shows.
/// </summary>
public interface ITransferOrderRepository
{
    Task<(IReadOnlyList<TransferOrderListItemDto> Items, int TotalCount, TransferOrderListTotalsDto Totals)> SearchAsync(
        TransferOrderQuery query, CancellationToken cancellationToken = default);

    /// <summary>The orders waiting for approval (stored status 4).</summary>
    Task<int> WaitingCountAsync(int userId, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<TransferAvailabilityDto>> AvailabilityAsync(
        int fromWarehouseId, int toWarehouseId, IReadOnlyCollection<int> itemIds, int? excludeOrderId,
        CancellationToken cancellationToken = default);

    /// <summary>The order with its lines, postings, history, returns and every action's answer for this reader; null when unknown.</summary>
    Task<TransferOrderDto?> GetAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Whether the order exists (the files' checks).</summary>
    Task<bool> ExistsAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The order a dispatch or receipt belongs to; null when the posting does not exist.</summary>
    Task<int?> PostingOrderIdAsync(int postingId, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or replaces a draft, lines and all; returns its id.</summary>
    Task<int> SaveAsync(
        int? id, SaveTransferOrderRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task UpdateDetailsAsync(
        int id, UpdateTransferDetailsRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task DeleteAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Releases a draft (an approver's Release approves it too); answers the warnings, one sentence per item.</summary>
    Task<IReadOnlyList<string>> ReleaseAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Sends a draft for approval; answers the approvers to tell (M10).</summary>
    Task<IReadOnlyList<TransferApproverDto>> SendForApprovalAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Approves a waiting order, or approves and releases a draft; answers Release's warnings and the requester to tell (none for a direct approval).</summary>
    Task<(IReadOnlyList<string> Warnings, TransferRequesterDto? Requester)> ApproveAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Back to draft with the reason; answers the requester to tell.</summary>
    Task<TransferRequesterDto?> RejectAsync(
        int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default);

    Task WithdrawAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task BackToDraftAsync(int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posts a dispatch; answers its id and number.</summary>
    Task<TransferPostedRefDto> DispatchAsync(
        int id, DispatchTransferRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posts a transfer receipt; answers its id and number.</summary>
    Task<TransferPostedRefDto> ReceiveAsync(
        int id, ReceiveTransferRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posts a dispatch and its receipt in one transaction; answers both.</summary>
    Task<(TransferPostedRefDto Dispatch, TransferPostedRefDto Receipt)> DispatchAndReceiveAsync(
        int id, DispatchTransferRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task NothingMoreSentAsync(int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default);

    /// <summary>Reverses one whole dispatch or receipt, in place (<paramref name="rowVersion"/> is the ORDER's).</summary>
    Task ReversePostingAsync(
        int postingId, byte[]? rowVersion, string? reason, DateOnly? date, int userId, CancellationToken cancellationToken = default);

    /// <summary>A new ETA for a dispatch with goods on the way (<paramref name="rowVersion"/> is the ORDER's).</summary>
    Task SetEtaAsync(int postingId, byte[]? rowVersion, DateOnly? eta, int userId, CancellationToken cancellationToken = default);

    /// <summary>A new draft from To back to From with what was received and no earlier return takes back; answers its id.</summary>
    Task<int> CreateReturnAsync(int id, int userId, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int transferOrderId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int transferOrderId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default);

    Task<DocumentFileDto?> UpdateFileAsync(int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default);

    Task<TransferOrderFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default);

    /* ── (91) Fill to Max, Add items below Min, a transfer order from Stock Levels ────────────── */

    /// <summary>
    /// inventory.usp_TransferOrder_FillToMax: no <paramref name="addItems"/> = Fill the order's lines, items = Add them.
    /// <paramref name="apply"/> false is the preview (nothing written, no lock); true writes the plan with the order's row
    /// version. The answer has no order: the service re-reads it after an apply.
    /// </summary>
    Task<TransferFillResult> FillToMaxAsync(
        int id, byte[]? rowVersion, IReadOnlyList<TransferFillItemRequest> addItems, bool apply, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_TransferOrder_BelowMinCandidates: the items with a level at the order's To, and the proposal per unit.</summary>
    Task<TransferBelowMinResult> BelowMinAsync(
        int id, TransferBelowMinQuery query, int userId, CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_TransferOrder_CreateFromLevels: one draft, filled, through the order's own Save.</summary>
    Task<CreateTransferFromLevelsResult> CreateFromLevelsAsync(
        CreateTransferFromLevelsRequest request, int userId, CancellationToken cancellationToken = default);
}

/// <summary>One stored file of a transfer order with its bytes (the download).</summary>
public sealed class TransferOrderFileContent
{
    public int Id { get; init; }

    /// <summary>The transfer order it belongs to.</summary>
    public int DocumentId { get; init; }

    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
