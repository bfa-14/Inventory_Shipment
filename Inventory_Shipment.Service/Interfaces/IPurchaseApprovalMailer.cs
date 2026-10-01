using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

public enum ApprovalRequestKind
{
    /// <summary>Sent for approval (a new request).</summary>
    Sent,

    /// <summary>Sent again by a user (new links, the older ones still valid).</summary>
    SentAgain,

    /// <summary>Sent again by the reminder worker.</summary>
    Reminder,
}

/// <summary>What the emails after a decision did: shown on the page as it is.</summary>
public sealed class ApprovalFollowUp
{
    public static ApprovalFollowUp Nothing { get; } = new();

    /// <summary>True emailed to the supplier, false not (no address), null nothing was to be sent.</summary>
    public bool? SupplierEmailed { get; init; }

    public IReadOnlyList<string> Warnings { get; init; } = [];
}

/// <summary>
/// Every email of the purchase approval cycle. Called after the procedure has decided - an email never
/// changes the outcome, and a failure to queue one is a warning, not an error of the action.
/// </summary>
public interface IPurchaseApprovalMailer
{
    /// <summary>The approval emails of a request (the rows with SendEmail = 1).</summary>
    Task RequestIssuedAsync(IReadOnlyList<ApprovalLinkRow> rows, ApprovalRequestKind kind, int? userId, CancellationToken cancellationToken = default);

    /// <summary>After an approval or a rejection: the supplier, the copies, the requester / the creator.</summary>
    Task<ApprovalFollowUp> DecidedAsync(ApprovalDecisionRow decision, int? userId, CancellationToken cancellationToken = default);

    /// <summary>After a purchase order was posted without approval (not needed): the supplier email and the copies.</summary>
    Task<ApprovalFollowUp> DecidedAsync(int purchaseDocumentId, int? userId, CancellationToken cancellationToken = default);

    /// <summary>The supplier email of an approved order, to the given addresses, the message as its first paragraph.</summary>
    Task SendToSupplierAsync(int purchaseDocumentId, string to, string? cc, string? message, int userId, CancellationToken cancellationToken = default);
}
