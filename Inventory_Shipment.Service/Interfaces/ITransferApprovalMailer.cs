using Inventory_Shipment.Model.DTOs.Inventory.Transfers;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// The emails of the transfer order approval cycle (script 90, D6), queued in the outbox; the worker sends them while
/// Settings › Email "Send emails" is on. Called AFTER the procedure has decided: an email never changes the outcome, and
/// a failure to queue one comes back as the action's emailWarning (null when everything was queued, or nothing had to be).
/// </summary>
public interface ITransferApprovalMailer
{
    /// <summary>"Approval needed: transfer order {No} ({From} → {To})" to each approver the procedure named (M10).</summary>
    Task<string?> ApprovalRequestedAsync(
        TransferOrderDto order, IReadOnlyList<TransferApproverDto> approvers, string? requestedByName, int? userId,
        CancellationToken cancellationToken = default);

    /// <summary>"Approved: transfer order {No} ({From} → {To})" to the requester (none for a direct approval).</summary>
    Task<string?> ApprovedAsync(
        TransferOrderDto order, TransferRequesterDto? requester, int approverId, int? userId,
        CancellationToken cancellationToken = default);

    /// <summary>"Rejected: transfer order {No} ({From} → {To})" to the requester, with the reason.</summary>
    Task<string?> RejectedAsync(
        TransferOrderDto order, TransferRequesterDto? requester, int approverId, string reason, int? userId,
        CancellationToken cancellationToken = default);
}
