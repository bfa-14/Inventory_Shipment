using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Purchase order approval: the settings, what waits for whom, the actions on one order, the emailed links.
/// WHO MAY APPROVE IS DECIDED BY SQL (Settings > Purchase approval); this service checks the purchase order
/// permissions of the action and that the links of the emails can be built. Tokens never leave it.
/// </summary>
public interface IPurchaseApprovalService
{
    Task<Result<ApprovalSettingsDto>> GetSettingsAsync(CancellationToken cancellationToken = default);

    Task<Result<ApprovalSettingsDto>> SaveSettingsAsync(SaveApprovalSettingsRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<ApprovalMeDto>> GetMeAsync(int userId, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<PendingApprovalDto>>> GetPendingAsync(int userId, CancellationToken cancellationToken = default);

    Task<Result<PurchaseOrderApprovalDto>> GetOrderApprovalAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApprovalRequestResultDto>> SendForApprovalAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApprovalRequestResultDto>> ResendAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApprovalDecisionResultDto>> WithdrawAsync(
        int id, WithdrawApprovalRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApprovalDecisionResultDto>> ApproveAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApprovalDecisionResultDto>> RejectAsync(
        int id, RejectPurchaseOrderRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApprovalDecisionResultDto>> ApproveNowAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<SendToSupplierResultDto>> SendToSupplierAsync(
        int id, SendToSupplierRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates the draft, then sends it for approval (or posts it when approval is not needed).</summary>
    Task<Result<CreateAndSendResultDto>> CreateAndSendAsync(
        SavePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates the draft, then approves it directly (or posts it when approval is not needed).</summary>
    Task<Result<CreateAndApproveResultDto>> CreateAndApproveAsync(
        SavePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The approval page of an emailed link: read only, it never decides.</summary>
    Task<Result<PublicApprovalDto>> GetPublicAsync(string token, CancellationToken cancellationToken = default);

    Task<Result<PublicDecisionResultDto>> DecidePublicAsync(string token, PublicDecisionRequest request, CancellationToken cancellationToken = default);
}
