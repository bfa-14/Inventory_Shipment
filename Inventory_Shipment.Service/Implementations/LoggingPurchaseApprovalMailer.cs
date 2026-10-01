using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Step A2's stand-in for the approval emails: it only logs what would be sent - counts, never a token.
/// Replaced by <c>PurchaseApprovalMailer</c> (step A3).
/// </summary>
public sealed class LoggingPurchaseApprovalMailer : IPurchaseApprovalMailer
{
    private readonly ILogger<LoggingPurchaseApprovalMailer> _logger;

    public LoggingPurchaseApprovalMailer(ILogger<LoggingPurchaseApprovalMailer> logger)
    {
        _logger = logger;
    }

    public Task RequestIssuedAsync(IReadOnlyList<ApprovalLinkRow> rows, ApprovalRequestKind kind, int? userId, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Approval {Kind}: {Orders} order(s), {Approvers} approver(s), {Emails} email(s) to send ({ByEmail} with a link, {InApp} in-app notices)",
            kind, rows.Select(r => r.PurchaseDocumentId).Distinct().Count(), rows.Count, rows.Count(r => r.SendEmail),
            rows.Count(r => r.SendEmail && r.Channel == "Email"), rows.Count(r => r.SendEmail && r.Channel == "App"));
        return Task.CompletedTask;
    }

    public Task<ApprovalFollowUp> DecidedAsync(ApprovalDecisionRow decision, int? userId, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Purchase order {DocumentId} {Decision} ({Channel}); follow-up emails not sent by this stand-in",
            decision.DocumentId, decision.Decision, decision.Channel);
        return Task.FromResult(ApprovalFollowUp.Nothing);
    }

    public Task<ApprovalFollowUp> DecidedAsync(int purchaseDocumentId, int? userId, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Purchase order {DocumentId} posted without approval; supplier email not sent by this stand-in", purchaseDocumentId);
        return Task.FromResult(ApprovalFollowUp.Nothing);
    }

    public Task SendToSupplierAsync(int purchaseDocumentId, string to, string? cc, string? message, int userId, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Purchase order {DocumentId}: send to the supplier asked by user {UserId}; not sent by this stand-in", purchaseDocumentId, userId);
        return Task.CompletedTask;
    }
}
