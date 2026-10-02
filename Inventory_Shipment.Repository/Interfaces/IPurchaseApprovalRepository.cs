using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Purchase order approval (scripts 26 and 42): requests, decisions, the history and the settings. The
/// procedures decide who may approve; every refusal comes back as a <see cref="Exceptions.BusinessRuleException"/>
/// (65004 changed meanwhile, 65010 wrong status, 65013-65017 and 65022-65024 the approval rules).
/// </summary>
public interface IPurchaseApprovalRepository
{
    /// <summary>Draft -> waiting for approval. One row per approver; tokens for the by-email ones.</summary>
    Task<IReadOnlyList<ApprovalLinkRow>> RequestApprovalAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>New links for the by-email approvers of a waiting order (the older ones stay valid).</summary>
    Task<IReadOnlyList<ApprovalLinkRow>> ResendAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Waiting -> draft; the links stop working.</summary>
    /// <summary>Waiting -> draft again; the reason (optional) is kept on the "Withdrawn" event.</summary>
    Task WithdrawAsync(int id, string? reason, int userId, CancellationToken cancellationToken = default);

    Task<ApprovalDecisionRow> DecideInAppAsync(int id, byte[]? rowVersion, bool approve, string? reason, int userId, CancellationToken cancellationToken = default);

    Task<ApprovalDecisionRow> ApproveDirectAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>The decision of the public approval page, with the emailed token.</summary>
    Task<ApprovalDecisionRow> DecideByTokenAsync(string token, bool approve, string? note, CancellationToken cancellationToken = default);

    /// <summary>The link behind a token; 65014 when it can no longer be used (the message says why).</summary>
    Task<ApprovalLinkInfo> GetByTokenAsync(string token, CancellationToken cancellationToken = default);

    /// <summary>New links for the orders waiting longer than ReminderHours; one row per approver of each.</summary>
    Task<IReadOnlyList<ApprovalLinkRow>> DueRemindersAsync(int maxOrders, CancellationToken cancellationToken = default);

    Task<(ApprovalStateDto State, IReadOnlyList<ApprovalApproverDto> Approvers)> GetStateAsync(
        int id, int userId, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<ApprovalEventDto>> GetHistoryAsync(int id, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<PendingApprovalDto>> GetPendingForUserAsync(int userId, CancellationToken cancellationToken = default);

    /// <summary>History event 8 (sent to the supplier) or 9 (not sent: no address).</summary>
    Task LogSupplierEmailAsync(int id, bool sent, string? recipients, int? userId, CancellationToken cancellationToken = default);

    Task<ApprovalSettingsDto> GetSettingsAsync(CancellationToken cancellationToken = default);

    /// <exception cref="Exceptions.BusinessRuleException">65024 validation, 65004 changed by someone else.</exception>
    Task<ApprovalSettingsDto> SaveSettingsAsync(SaveApprovalSettingsRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task<ApprovalMeDto> GetForUserAsync(int userId, CancellationToken cancellationToken = default);
}
