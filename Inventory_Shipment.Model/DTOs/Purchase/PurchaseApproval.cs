using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/* ── Settings > Purchase approval ─────────────────────────────────────────────────────────────── */

public sealed class ApprovalRulesDto
{
    public bool RequireApproval { get; init; }

    /// <summary>Orders whose total in the base currency is not above this are posted without approval; 0 = every order.</summary>
    public decimal ApprovalLimitBase { get; init; }

    public string? BaseCurrencyCode { get; init; }
    public bool AllowSelfApproval { get; init; }
    public int LinkValidHours { get; init; }
    public int ReminderHours { get; init; }
    public bool NotifyAppApprovers { get; init; }
    public bool EmailSupplierOnApproval { get; init; }
    public bool CopyToOwners { get; init; }
    public string? CopyToEmails { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>Every active user, with their approval rights (both false = not an approver).</summary>
public sealed class ApprovalUserDto
{
    public int UserId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string UserName { get; init; } = string.Empty;
    public string? Email { get; init; }
    public string? Roles { get; init; }
    public bool IsAdministrator { get; init; }
    public bool CanApproveInApp { get; init; }
    public bool CanApproveByEmail { get; init; }
}

public sealed class ApprovalSettingsDto
{
    public ApprovalRulesDto Settings { get; init; } = new();
    public IReadOnlyList<ApprovalUserDto> Users { get; init; } = [];
}

public sealed class ApproverRightsRequest
{
    [Range(1, int.MaxValue)]
    public int UserId { get; init; }

    public bool CanApproveInApp { get; init; }
    public bool CanApproveByEmail { get; init; }
}

public sealed class SaveApprovalSettingsRequest
{
    public bool RequireApproval { get; init; }
    public decimal ApprovalLimitBase { get; init; }
    public bool AllowSelfApproval { get; init; }
    public int LinkValidHours { get; init; }
    public int ReminderHours { get; init; }
    public bool NotifyAppApprovers { get; init; }
    public bool EmailSupplierOnApproval { get; init; }
    public bool CopyToOwners { get; init; }

    /// <summary>Addresses separated by ";" or ",".</summary>
    [StringLength(1000)]
    public string? CopyToEmails { get; init; }

    /// <summary>Every user row of the page; a row with both rights false is not an approver.</summary>
    public IReadOnlyList<ApproverRightsRequest> Approvers { get; init; } = [];

    public string? RowVersion { get; init; }
}

/* ── for every signed-in user ─────────────────────────────────────────────────────────────────── */

public sealed class ApprovalMeDto
{
    public bool CanApproveInApp { get; init; }
    public bool CanApproveByEmail { get; init; }
    public bool RequireApproval { get; init; }
    public bool AllowSelfApproval { get; init; }
    public decimal ApprovalLimitBase { get; init; }
    public string? BaseCurrencyCode { get; init; }

    /// <summary>Orders waiting that this user can approve in the app (the menu badge).</summary>
    public int PendingCount { get; init; }
}

public sealed class PendingApprovalDto
{
    public int Id { get; init; }
    public string Reference { get; init; } = string.Empty;
    public int SupplierId { get; init; }
    public string SupplierName { get; init; } = string.Empty;
    public DateTime OrderDate { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public decimal Total { get; init; }
    public decimal TotalBase { get; init; }
    public int LineCount { get; init; }
    public string? RequestedByName { get; init; }
    public DateTime? RequestedAtUtc { get; init; }
    public int? WaitingHours { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/* ── one purchase order ───────────────────────────────────────────────────────────────────────── */

/// <summary>usp_PurchaseOrder_ApprovalState, first result set, as seen by the signed-in user.</summary>
public sealed class ApprovalStateDto
{
    /// <summary>Draft | PendingApproval | Posted | Cancelled | Closed.</summary>
    public string Status { get; init; } = PurchaseDocumentStatus.Draft;

    public bool NeedsApproval { get; init; }
    public bool RequireApproval { get; init; }
    public decimal ApprovalLimitBase { get; init; }
    public string? BaseCurrencyCode { get; init; }
    public decimal TotalBase { get; init; }
    public bool AllowSelfApproval { get; init; }
    public bool UserCanApproveInApp { get; init; }
    public bool CanApproveDirect { get; init; }
    public int? RequestedBy { get; init; }
    public string? RequestedByName { get; init; }
    public DateTime? RequestedAtUtc { get; init; }
    public DateTime? LinksValidUntilUtc { get; init; }
    public DateTime? NextReminderAtUtc { get; init; }
    public string? LastRejectedByName { get; init; }
    public DateTime? LastRejectedAtUtc { get; init; }
    public string? LastRejectReason { get; init; }
    public string? SupplierEmail { get; init; }
    public DateTime? SentToSupplierAtUtc { get; init; }
    public bool SupplierNotEmailed { get; init; }
}

public sealed class ApprovalApproverDto
{
    public int UserId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string? Email { get; init; }
    public bool CanApproveInApp { get; init; }
    public bool CanApproveByEmail { get; init; }
    public DateTime? LinkExpiresAtUtc { get; init; }
}

public sealed class ApprovalEventDto
{
    public long Id { get; init; }
    public byte EventType { get; init; }
    public string EventName { get; init; } = string.Empty;
    public byte? Channel { get; init; }
    public string? ChannelName { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public string? Recipients { get; init; }
    public string? Reason { get; init; }
    public string? Note { get; init; }
    public DateTime AtUtc { get; init; }
}

public sealed class PurchaseOrderApprovalDto
{
    public ApprovalStateDto State { get; init; } = new();
    public IReadOnlyList<ApprovalApproverDto> Approvers { get; init; } = [];
    public IReadOnlyList<ApprovalEventDto> History { get; init; } = [];
}

/* ── actions ──────────────────────────────────────────────────────────────────────────────────── */

public sealed class ApprovalActionRequest
{
    public string? RowVersion { get; init; }
}

public sealed class RejectPurchaseOrderRequest
{
    [StringLength(500)]
    public string? Reason { get; init; }

    public string? RowVersion { get; init; }
}

public sealed class WithdrawApprovalRequest
{
    [StringLength(500)]
    public string? Reason { get; init; }

    public string? RowVersion { get; init; }
}

public sealed class SendToSupplierRequest
{
    /// <summary>One or several addresses separated by ";" or ",".</summary>
    [Required]
    [StringLength(1000)]
    public string To { get; init; } = string.Empty;

    [StringLength(1000)]
    public string? Cc { get; init; }

    /// <summary>The first paragraph of the email.</summary>
    [StringLength(2000)]
    public string? Message { get; init; }
}

/// <summary>Who an order was sent to and how - never a token.</summary>
public sealed class ApprovalRecipientDto
{
    public string FullName { get; init; } = string.Empty;

    /// <summary>Email (a personal link) | App (approves in the application).</summary>
    public string Channel { get; init; } = string.Empty;
}

public sealed class ApprovalRequestResultDto
{
    public IReadOnlyList<ApprovalRecipientDto> Approvers { get; init; } = [];
    public string Message { get; init; } = string.Empty;
}

public sealed class ApprovalDecisionResultDto
{
    public int Id { get; init; }
    public string Status { get; init; } = string.Empty;
    public string? DocumentNumber { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /// <summary>True sent, false not sent (no address), null nothing was to be sent (a rejection, or switched off).</summary>
    public bool? SupplierEmailed { get; init; }

    public IReadOnlyList<string> Warnings { get; init; } = [];
    public string Message { get; init; } = string.Empty;
}

public sealed class SendToSupplierResultDto
{
    public bool Sent { get; init; }
    public string To { get; init; } = string.Empty;
    public string Message { get; init; } = string.Empty;
}

public sealed class CreateAndSendResultDto
{
    public int Id { get; init; }
    public string Status { get; init; } = string.Empty;
    public string? DocumentNumber { get; init; }
    public bool ApprovalRequested { get; init; }
    public bool Posted { get; init; }
    public IReadOnlyList<ApprovalRecipientDto> Approvers { get; init; } = [];
    public string Message { get; init; } = string.Empty;
}

public sealed class CreateAndApproveResultDto
{
    public int Id { get; init; }
    public string Status { get; init; } = string.Empty;
    public string? DocumentNumber { get; init; }
    public bool Approved { get; init; }
    public bool Posted { get; init; }
    public string Message { get; init; } = string.Empty;
}

/* ── the public approval page (no sign-in) ────────────────────────────────────────────────────── */

public sealed class PublicApprovalOrderDto
{
    public string? DocumentNumber { get; init; }
    public string SupplierName { get; init; } = string.Empty;
    public DateTime OrderDate { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public byte DecimalPlaces { get; init; }
    public decimal Total { get; init; }
    public int LineCount { get; init; }
    public string? RequestedByName { get; init; }
    public DateTime? RequestedAtUtc { get; init; }
    public string? Notes { get; init; }
}

public sealed class PublicApprovalLineDto
{
    public int LineNo { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string UnitName { get; init; } = string.Empty;
    public int Quantity { get; init; }
    public decimal UnitPrice { get; init; }
    public decimal LineTotal { get; init; }
}

public sealed class PublicApprovalDto
{
    public PublicApprovalOrderDto Order { get; init; } = new();
    public IReadOnlyList<PublicApprovalLineDto> Lines { get; init; } = [];
    public string ApproverName { get; init; } = string.Empty;
    public DateTime LinkExpiresAtUtc { get; init; }
}

public sealed class PublicDecisionRequest
{
    public bool Approve { get; init; }

    [StringLength(300)]
    public string? Reason { get; init; }
}

public sealed class PublicDecisionResultDto
{
    public string Status { get; init; } = string.Empty;
    public string? DocumentNumber { get; init; }
    public string Message { get; init; } = string.Empty;
}

/* ── rows of the procedures (tokens live only here and in the queued emails) ──────────────────── */

/// <summary>
/// One approver of a request (usp_PurchaseOrder_RequestApproval / _Resend / _DueReminders). THE TOKEN IS
/// SECRET: it goes into that approver's email and nowhere else - <see cref="ToString"/> leaves it out.
/// </summary>
public sealed class ApprovalLinkRow
{
    public int PurchaseDocumentId { get; set; }
    public int UserId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string? Email { get; init; }

    /// <summary>Hex, 64 characters; null for an in-app approver (no personal link).</summary>
    public string? Token { get; init; }

    public DateTime? ExpiresAtUtc { get; init; }
    public int RequestNo { get; init; }

    /// <summary>Email | App.</summary>
    public string Channel { get; init; } = string.Empty;

    public bool CanApproveInApp { get; init; }
    public bool SendEmail { get; init; }

    /// <summary>Reminders only: since when the order waits.</summary>
    public DateTime? WaitingSinceUtc { get; init; }

    public override string ToString() => $"{FullName} ({Channel}, order {PurchaseDocumentId}, email {(SendEmail ? "yes" : "no")})";
}

/// <summary>usp_PurchaseOrder_Decide / _DecideInApp / _ApproveDirect: the decision and what the follow-up emails need.</summary>
public sealed class ApprovalDecisionRow
{
    public int DocumentId { get; init; }
    public string? DocumentNumber { get; init; }

    /// <summary>Approved | Rejected.</summary>
    public string Decision { get; init; } = string.Empty;

    public string? DecidedByName { get; init; }
    public string? DecisionNote { get; init; }

    /// <summary>Email | App.</summary>
    public string Channel { get; init; } = string.Empty;

    public string? SupplierName { get; init; }
    public string? SupplierEmail { get; init; }
    public string? CreatorName { get; init; }
    public string? CreatorEmail { get; init; }
    public string? RequestedByName { get; init; }
    public string? RequestedByEmail { get; init; }

    /// <summary>The active Owner users' addresses, separated by ";".</summary>
    public string? OwnerEmails { get; init; }

    public byte Status { get; init; }
    public byte[] RowVersion { get; init; } = [];
    public int? DecidedBy { get; init; }
    public string? DecidedByEmail { get; init; }
    public int? CreatedBy { get; init; }
    public int? RequestedBy { get; init; }
    public int SupplierId { get; init; }
    public byte ChannelId { get; init; }

    /// <summary>Approved directly, without a request.</summary>
    public bool Direct { get; init; }

    public bool EmailSupplierOnApproval { get; init; }
    public bool CopyToOwners { get; init; }
    public string? CopyToEmails { get; init; }

    public bool Approved => string.Equals(Decision, "Approved", StringComparison.OrdinalIgnoreCase);
}

/// <summary>usp_PurchaseOrder_GetByToken: the link that was opened (never the token itself).</summary>
public sealed class ApprovalLinkInfo
{
    public int ApprovalId { get; init; }
    public int DocumentId { get; init; }
    public int RequestNo { get; init; }
    public int ApproverUserId { get; init; }
    public string ApproverName { get; init; } = string.Empty;
    public DateTime ExpiresAtUtc { get; init; }
    public DateTime RequestedAtUtc { get; init; }
    public string? RequestedByName { get; init; }
}
