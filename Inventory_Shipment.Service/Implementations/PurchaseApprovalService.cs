using System.Text.RegularExpressions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed partial class PurchaseApprovalService : IPurchaseApprovalService
{
    private const string LinksNotSetMessage = "Set the address of the application in Settings > Email first.";
    private const string NotApprovedLinkMessage = "This approval link is not valid.";

    private readonly IPurchaseApprovalRepository _approvals;
    private readonly IPurchaseDocumentRepository _documents;
    private readonly IPurchaseDocumentService _documentService;
    private readonly IPurchaseApprovalMailer _mailer;
    private readonly IEmailSettingsProvider _emailSettings;
    private readonly ILogger<PurchaseApprovalService> _logger;

    public PurchaseApprovalService(
        IPurchaseApprovalRepository approvals, IPurchaseDocumentRepository documents, IPurchaseDocumentService documentService,
        IPurchaseApprovalMailer mailer, IEmailSettingsProvider emailSettings, ILogger<PurchaseApprovalService> logger)
    {
        _approvals = approvals;
        _documents = documents;
        _documentService = documentService;
        _mailer = mailer;
        _emailSettings = emailSettings;
        _logger = logger;
    }

    /* ── settings ─────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ApprovalSettingsDto>> GetSettingsAsync(CancellationToken cancellationToken = default)
        => Result<ApprovalSettingsDto>.Success(await _approvals.GetSettingsAsync(cancellationToken));

    public async Task<Result<ApprovalSettingsDto>> SaveSettingsAsync(
        SaveApprovalSettingsRequest request, int userId, CancellationToken cancellationToken = default)
    {
        // The copies are the API's to check: the procedure stores the text as it is given.
        var copies = EmailAddresses.Split(request.CopyToEmails);
        var wrong = copies.FirstOrDefault(address => !EmailAddresses.IsValid(address));
        if (wrong is not null)
        {
            return Result<ApprovalSettingsDto>.Failure(ErrorType.Validation, $"Not a valid email address: {wrong}", "VALIDATION");
        }

        var normalized = new SaveApprovalSettingsRequest
        {
            RequireApproval = request.RequireApproval,
            ApprovalLimitBase = request.ApprovalLimitBase,
            AllowSelfApproval = request.AllowSelfApproval,
            LinkValidHours = request.LinkValidHours,
            ReminderHours = request.ReminderHours,
            NotifyAppApprovers = request.NotifyAppApprovers,
            EmailSupplierOnApproval = request.EmailSupplierOnApproval,
            CopyToOwners = request.CopyToOwners,
            CopyToEmails = copies.Count == 0 ? null : string.Join("; ", copies),
            Approvers = request.Approvers,
        };

        try
        {
            var saved = await _approvals.SaveSettingsAsync(normalized, ToRowVersion(request.RowVersion), userId, cancellationToken);
            _logger.LogInformation("Purchase approval settings saved by user {UserId}: approval {Required}, {Approvers} approver(s)",
                userId, request.RequireApproval ? "required" : "off", saved.Users.Count(u => u.CanApproveInApp || u.CanApproveByEmail));
            return Result<ApprovalSettingsDto>.Success(saved);
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<ApprovalSettingsDto>(ex);
        }
    }

    /* ── for every signed-in user ─────────────────────────────────────────────────────────────── */

    public async Task<Result<ApprovalMeDto>> GetMeAsync(int userId, CancellationToken cancellationToken = default)
        => Result<ApprovalMeDto>.Success(await _approvals.GetForUserAsync(userId, cancellationToken));

    public async Task<Result<IReadOnlyList<PendingApprovalDto>>> GetPendingAsync(int userId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<PendingApprovalDto>>.Success(await _approvals.GetPendingForUserAsync(userId, cancellationToken));

    /* ── one purchase order ───────────────────────────────────────────────────────────────────── */

    public async Task<Result<PurchaseOrderApprovalDto>> GetOrderApprovalAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowOrderAsync<PurchaseOrderApprovalDto>(id, Permissions.Purchase.OrdersView, permissions, cancellationToken);
        if (allowed is not null)
        {
            return allowed;
        }

        try
        {
            var (state, approvers) = await _approvals.GetStateAsync(id, userId, cancellationToken);
            var history = await _approvals.GetHistoryAsync(id, cancellationToken);
            return Result<PurchaseOrderApprovalDto>.Success(new PurchaseOrderApprovalDto { State = state, Approvers = approvers, History = history });
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<PurchaseOrderApprovalDto>(ex);
        }
    }

    public Task<Result<ApprovalRequestResultDto>> SendForApprovalAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => RequestAsync(id, rowVersion, userId, permissions, ApprovalRequestKind.Sent, cancellationToken);

    public Task<Result<ApprovalRequestResultDto>> ResendAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => RequestAsync(id, rowVersion, userId, permissions, ApprovalRequestKind.SentAgain, cancellationToken);

    public async Task<Result<ApprovalDecisionResultDto>> WithdrawAsync(
        int id, WithdrawApprovalRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowOrderAsync<ApprovalDecisionResultDto>(id, Permissions.Purchase.OrdersPost, permissions, cancellationToken);
        if (allowed is not null)
        {
            return allowed;
        }

        // usp_PurchaseOrder_Withdraw takes no row version: the page's version is compared here.
        var expected = ToRowVersion(request.RowVersion);
        var current = await _documents.GetAsync(id, cancellationToken);
        if (expected is not null && current is not null && !expected.AsSpan().SequenceEqual(current.RowVersion))
        {
            return Result<ApprovalDecisionResultDto>.Failure(ErrorType.Conflict,
                "This document was modified by another user. Reload the page and try again.", "CONCURRENCY");
        }

        try
        {
            await _approvals.WithdrawAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<ApprovalDecisionResultDto>(ex);
        }

        // The procedure keeps no reason for a withdrawal; it is logged so it is not lost.
        _logger.LogInformation("Approval request of purchase order {DocumentId} withdrawn by user {UserId}{Reason}",
            id, userId, string.IsNullOrWhiteSpace(request.Reason) ? string.Empty : ": " + request.Reason.Trim());

        return await DocumentResultAsync(id, ApprovalFollowUp.Nothing, "Approval request withdrawn: the order is a draft again.", cancellationToken);
    }

    public Task<Result<ApprovalDecisionResultDto>> ApproveAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => DecideAsync(id, permissions, userId,
            () => _approvals.DecideInAppAsync(id, ToRowVersion(rowVersion), true, null, userId, cancellationToken), cancellationToken);

    public Task<Result<ApprovalDecisionResultDto>> RejectAsync(
        int id, RejectPurchaseOrderRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => DecideAsync(id, permissions, userId,
            () => _approvals.DecideInAppAsync(id, ToRowVersion(request.RowVersion), false, request.Reason?.Trim(), userId, cancellationToken),
            cancellationToken);

    public Task<Result<ApprovalDecisionResultDto>> ApproveNowAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => DecideAsync(id, permissions, userId,
            () => _approvals.ApproveDirectAsync(id, ToRowVersion(rowVersion), userId, cancellationToken), cancellationToken);

    public async Task<Result<SendToSupplierResultDto>> SendToSupplierAsync(
        int id, SendToSupplierRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowOrderAsync<SendToSupplierResultDto>(id, Permissions.Purchase.OrdersPost, permissions, cancellationToken);
        if (allowed is not null)
        {
            return allowed;
        }

        var document = await _documents.GetAsync(id, cancellationToken);
        if (document is null || document.Status is not (PurchaseDocumentStatus.Posted or PurchaseDocumentStatus.Closed))
        {
            return Result<SendToSupplierResultDto>.Failure(ErrorType.Conflict,
                "Only an approved purchase order can be sent to the supplier.", "INVALID_STATUS");
        }

        var to = EmailAddresses.Split(request.To);
        var cc = EmailAddresses.Split(request.Cc);
        var wrong = to.Concat(cc).FirstOrDefault(address => !EmailAddresses.IsValid(address));
        if (to.Count == 0 || wrong is not null)
        {
            return Result<SendToSupplierResultDto>.Failure(ErrorType.Validation,
                wrong is null ? "Enter the supplier's email address." : $"Not a valid email address: {wrong}", "VALIDATION");
        }

        var toList = string.Join("; ", to);
        await _mailer.SendToSupplierAsync(id, toList, cc.Count == 0 ? null : string.Join("; ", cc), request.Message, userId, cancellationToken);
        return Result<SendToSupplierResultDto>.Success(new SendToSupplierResultDto
        {
            Sent = true,
            To = toList,
            Message = $"Purchase order {document.DocumentNumber} sent to {toList}.",
        });
    }

    /* ── a new purchase order in one call ─────────────────────────────────────────────────────── */

    public async Task<Result<CreateAndSendResultDto>> CreateAndSendAsync(
        SavePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var refused = CheckCreate<CreateAndSendResultDto>(request, permissions);
        if (refused is not null)
        {
            return refused;
        }

        var created = await _documentService.SaveDraftAsync(null, request, userId, permissions, cancellationToken);
        if (created.IsFailure || created.Value is null)
        {
            return Result<CreateAndSendResultDto>.Failure(created.ErrorType, created.Error ?? string.Empty, created.Code ?? "ERROR");
        }

        var draft = created.Value;
        if (await LinksMissingAsync(cancellationToken))
        {
            return Result<CreateAndSendResultDto>.Success(Draft(draft, LinksNotSetMessage));
        }

        IReadOnlyList<ApprovalLinkRow> rows;
        try
        {
            rows = await _approvals.RequestApprovalAsync(draft.Id, draft.RowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.ApprovalNotNeeded)
        {
            var posted = await _documentService.PostAsync(draft.Id, Convert.ToBase64String(draft.RowVersion), userId, permissions, cancellationToken);
            return Result<CreateAndSendResultDto>.Success(posted.IsSuccess && posted.Value is not null
                ? new CreateAndSendResultDto
                {
                    Id = draft.Id, Status = posted.Value.Status, DocumentNumber = posted.Value.DocumentNumber,
                    ApprovalRequested = false, Posted = true, Message = "Approval not needed: the order is posted.",
                }
                : Draft(draft, posted.Error ?? "The order could not be posted."));
        }
        catch (BusinessRuleException ex)
        {
            return Result<CreateAndSendResultDto>.Success(Draft(draft, ex.Message));
        }

        await _mailer.RequestIssuedAsync(rows, ApprovalRequestKind.Sent, userId, cancellationToken);
        var current = await _documents.GetAsync(draft.Id, cancellationToken);
        return Result<CreateAndSendResultDto>.Success(new CreateAndSendResultDto
        {
            Id = draft.Id,
            Status = current?.Status ?? PurchaseDocumentStatus.PendingApproval,
            DocumentNumber = current?.DocumentNumber ?? draft.DocumentNumber,
            ApprovalRequested = true,
            Posted = false,
            Approvers = Recipients(rows),
            Message = SentMessage(rows, ApprovalRequestKind.Sent),
        });

        static CreateAndSendResultDto Draft(PurchaseDocumentDto draft, string message) => new()
        {
            Id = draft.Id, Status = draft.Status, DocumentNumber = draft.DocumentNumber,
            ApprovalRequested = false, Posted = false, Message = message,
        };
    }

    public async Task<Result<CreateAndApproveResultDto>> CreateAndApproveAsync(
        SavePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var refused = CheckCreate<CreateAndApproveResultDto>(request, permissions);
        if (refused is not null)
        {
            return refused;
        }

        var created = await _documentService.SaveDraftAsync(null, request, userId, permissions, cancellationToken);
        if (created.IsFailure || created.Value is null)
        {
            return Result<CreateAndApproveResultDto>.Failure(created.ErrorType, created.Error ?? string.Empty, created.Code ?? "ERROR");
        }

        var draft = created.Value;
        ApprovalDecisionRow decision;
        try
        {
            decision = await _approvals.ApproveDirectAsync(draft.Id, draft.RowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.ApprovalNotNeeded)
        {
            var posted = await _documentService.PostAsync(draft.Id, Convert.ToBase64String(draft.RowVersion), userId, permissions, cancellationToken);
            return Result<CreateAndApproveResultDto>.Success(posted.IsSuccess && posted.Value is not null
                ? new CreateAndApproveResultDto
                {
                    Id = draft.Id, Status = posted.Value.Status, DocumentNumber = posted.Value.DocumentNumber,
                    Approved = false, Posted = true, Message = "Approval not needed: the order is posted.",
                }
                : Draft(draft, posted.Error ?? "The order could not be posted."));
        }
        catch (BusinessRuleException ex)
        {
            return Result<CreateAndApproveResultDto>.Success(Draft(draft, ex.Message));
        }

        await _mailer.DecidedAsync(decision, userId, cancellationToken);
        return Result<CreateAndApproveResultDto>.Success(new CreateAndApproveResultDto
        {
            Id = draft.Id,
            Status = PurchaseDocumentStatus.From(decision.Status),
            DocumentNumber = decision.DocumentNumber,
            Approved = true,
            Posted = true,
            Message = $"Approved: {decision.DocumentNumber}",
        });

        static CreateAndApproveResultDto Draft(PurchaseDocumentDto draft, string message) => new()
        {
            Id = draft.Id, Status = draft.Status, DocumentNumber = draft.DocumentNumber,
            Approved = false, Posted = false, Message = message,
        };
    }

    /* ── the public approval page ─────────────────────────────────────────────────────────────── */

    public async Task<Result<PublicApprovalDto>> GetPublicAsync(string token, CancellationToken cancellationToken = default)
    {
        if (!IsToken(token))
        {
            return Result<PublicApprovalDto>.Failure(ErrorType.Gone, NotApprovedLinkMessage, "LINK_NOT_USABLE");
        }

        ApprovalLinkInfo link;
        try
        {
            link = await _approvals.GetByTokenAsync(token, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<PublicApprovalDto>(ex);
        }

        var document = await _documents.GetAsync(link.DocumentId, cancellationToken);
        if (document is null)
        {
            return Result<PublicApprovalDto>.Failure(ErrorType.Gone, NotApprovedLinkMessage, "LINK_NOT_USABLE");
        }

        return Result<PublicApprovalDto>.Success(new PublicApprovalDto
        {
            Order = new PublicApprovalOrderDto
            {
                DocumentNumber = document.DocumentNumber,
                SupplierName = document.SupplierName,
                OrderDate = document.DocumentDate,
                CurrencyCode = document.CurrencyCode,
                DecimalPlaces = document.DecimalPlaces,
                Total = document.TotalAmount,
                LineCount = document.Lines.Count,
                RequestedByName = link.RequestedByName,
                RequestedAtUtc = link.RequestedAtUtc,
                Notes = document.Notes,
            },
            Lines = document.Lines.Select(line => new PublicApprovalLineDto
            {
                LineNo = line.LineNo,
                ItemCode = line.ItemCode,
                ItemName = line.ItemName,
                UnitName = line.UnitTypeName,
                Quantity = line.Quantity,
                UnitPrice = line.UnitPrice,
                LineTotal = line.LineTotal,
            }).ToList(),
            ApproverName = link.ApproverName,
            LinkExpiresAtUtc = link.ExpiresAtUtc,
        });
    }

    public async Task<Result<PublicDecisionResultDto>> DecidePublicAsync(
        string token, PublicDecisionRequest request, CancellationToken cancellationToken = default)
    {
        if (!IsToken(token))
        {
            return Result<PublicDecisionResultDto>.Failure(ErrorType.Gone, NotApprovedLinkMessage, "LINK_NOT_USABLE");
        }

        ApprovalDecisionRow decision;
        try
        {
            decision = await _approvals.DecideByTokenAsync(token, request.Approve, request.Reason?.Trim(), cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<PublicDecisionResultDto>(ex);
        }

        _logger.LogInformation("Purchase order {DocumentId} {Decision} by user {UserId} from an emailed link",
            decision.DocumentId, decision.Decision, decision.DecidedBy);
        await _mailer.DecidedAsync(decision, decision.DecidedBy, cancellationToken);

        return Result<PublicDecisionResultDto>.Success(new PublicDecisionResultDto
        {
            Status = PurchaseDocumentStatus.From(decision.Status),
            DocumentNumber = decision.DocumentNumber,
            Message = decision.Approved ? $"Approved: {decision.DocumentNumber}" : "Rejected: the order is back with its requester.",
        });
    }

    /* ── shared ───────────────────────────────────────────────────────────────────────────────── */

    private async Task<Result<ApprovalRequestResultDto>> RequestAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, ApprovalRequestKind kind, CancellationToken cancellationToken)
    {
        var allowed = await AllowOrderAsync<ApprovalRequestResultDto>(id, Permissions.Purchase.OrdersPost, permissions, cancellationToken);
        if (allowed is not null)
        {
            return allowed;
        }

        // Before anything is changed: an email whose link points nowhere is worse than no email.
        if (await LinksMissingAsync(cancellationToken))
        {
            return Result<ApprovalRequestResultDto>.Failure(ErrorType.Conflict, LinksNotSetMessage, "EMAIL_LINKS_NOT_SET");
        }

        IReadOnlyList<ApprovalLinkRow> rows;
        try
        {
            rows = kind == ApprovalRequestKind.Sent
                ? await _approvals.RequestApprovalAsync(id, ToRowVersion(rowVersion), userId, cancellationToken)
                : await _approvals.ResendAsync(id, ToRowVersion(rowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<ApprovalRequestResultDto>(ex);
        }

        await _mailer.RequestIssuedAsync(rows, kind, userId, cancellationToken);
        _logger.LogInformation("Purchase order {DocumentId} {Kind} by user {UserId} to {Count} approver(s)", id, kind, userId, rows.Count);

        return Result<ApprovalRequestResultDto>.Success(new ApprovalRequestResultDto
        {
            Approvers = Recipients(rows),
            Message = SentMessage(rows, kind),
        });
    }

    private async Task<Result<ApprovalDecisionResultDto>> DecideAsync(
        int id, IReadOnlySet<string> permissions, int userId, Func<Task<ApprovalDecisionRow>> decide, CancellationToken cancellationToken)
    {
        // Seeing the order is enough to reach the procedure; whether this user may decide is SQL's to say.
        var allowed = await AllowOrderAsync<ApprovalDecisionResultDto>(id, Permissions.Purchase.OrdersView, permissions, cancellationToken);
        if (allowed is not null)
        {
            return allowed;
        }

        ApprovalDecisionRow decision;
        try
        {
            decision = await decide();
        }
        catch (BusinessRuleException ex)
        {
            return ApprovalRuleFailures.Failure<ApprovalDecisionResultDto>(ex);
        }

        _logger.LogInformation("Purchase order {DocumentId} {Decision} in the app by user {UserId}", id, decision.Decision, userId);
        var followUp = await _mailer.DecidedAsync(decision, userId, cancellationToken);
        var message = decision.Approved ? $"Approved: {decision.DocumentNumber}" : "Rejected: the order is a draft again.";
        return await DocumentResultAsync(id, followUp, message, cancellationToken);
    }

    private async Task<Result<ApprovalDecisionResultDto>> DocumentResultAsync(
        int id, ApprovalFollowUp followUp, string message, CancellationToken cancellationToken)
    {
        var document = await _documents.GetAsync(id, cancellationToken);
        return document is null
            ? Result<ApprovalDecisionResultDto>.Failure(ErrorType.NotFound, "Document not found.", "NOT_FOUND")
            : Result<ApprovalDecisionResultDto>.Success(new ApprovalDecisionResultDto
            {
                Id = id,
                Status = document.Status,
                DocumentNumber = document.DocumentNumber,
                RowVersion = document.RowVersion,
                SupplierEmailed = followUp.SupplierEmailed,
                Warnings = followUp.Warnings,
                Message = message,
            });
    }

    /// <summary>Null when the caller may act on this purchase order; else the refusal (404, 400 not an order, 403).</summary>
    private async Task<Result<T>?> AllowOrderAsync<T>(int id, string permission, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var stub = await _documents.GetStubAsync(id, cancellationToken);
        if (stub is null)
        {
            return Result<T>.Failure(ErrorType.NotFound, "Document not found.", "NOT_FOUND");
        }

        if (!string.Equals(stub.DocumentTypeCode, PurchaseDocumentTypes.Order, StringComparison.OrdinalIgnoreCase))
        {
            return Result<T>.Failure(ErrorType.Validation, "Only purchase orders go through approval.", "VALIDATION");
        }

        return permissions.Contains(permission)
            ? null
            : Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", "FORBIDDEN");
    }

    /// <summary>Create-and-send / create-and-approve: a purchase order, and every permission checked BEFORE anything is created.</summary>
    private static Result<T>? CheckCreate<T>(SavePurchaseDocumentRequest request, IReadOnlySet<string> permissions)
    {
        if (!string.Equals(PurchaseDocumentTypes.Normalize(request.DocumentTypeCode), PurchaseDocumentTypes.Order, StringComparison.Ordinal))
        {
            return Result<T>.Failure(ErrorType.Validation, "Only a purchase order (documentTypeCode PO) is created and sent this way.", "VALIDATION");
        }

        var missing = new[] { Permissions.Purchase.OrdersCreate, Permissions.Purchase.OrdersPost }.FirstOrDefault(p => !permissions.Contains(p));
        return missing is null
            ? null
            : Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {missing} permission.", "FORBIDDEN");
    }

    private async Task<bool> LinksMissingAsync(CancellationToken cancellationToken)
        => string.IsNullOrEmpty((await _emailSettings.GetAsync(cancellationToken)).PublicBaseUrl);

    private static IReadOnlyList<ApprovalRecipientDto> Recipients(IReadOnlyList<ApprovalLinkRow> rows)
        => rows.Select(row => new ApprovalRecipientDto { FullName = row.FullName, Channel = row.Channel }).ToList();

    /// <summary>"Sent for approval to Ann, Bob and Carl".</summary>
    private static string SentMessage(IReadOnlyList<ApprovalLinkRow> rows, ApprovalRequestKind kind)
    {
        var names = rows.Select(row => row.FullName).ToList();
        var list = names.Count <= 1 ? string.Join(string.Empty, names) : string.Join(", ", names[..^1]) + " and " + names[^1];
        return (kind == ApprovalRequestKind.Sent ? "Sent for approval to " : "Sent again to ") + list;
    }

    private static bool IsToken(string? token) => token is { Length: 64 } && HexToken().IsMatch(token);

    private static byte[]? ToRowVersion(string? value)
        => !string.IsNullOrWhiteSpace(value) && Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;

    [GeneratedRegex("^[0-9A-Fa-f]{64}$")]
    private static partial Regex HexToken();
}
