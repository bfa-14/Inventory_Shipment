using System.Globalization;
using System.Text;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.PurchaseEmailHtml;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The emails of the transfer order approval cycle (script 90), queued in the outbox like the purchase approval's
/// (<see cref="PurchaseApprovalMailer"/>): the request to the approvers, the decision to the requester.
///
/// AN EMAIL NEVER DECIDES ANYTHING. It is queued after the procedure has decided and outside its transaction; a failure
/// to queue one becomes the action's warning, never its failure. THE RECIPIENTS ARE THE PROCEDURE'S
/// (inventory.usp_TransferOrder_Approvers, M10): the approvers outside the system role, the system role's holders only
/// when nobody else may approve - Admin holds every permission and would otherwise get every request.
///
/// ONLY WITH AN ADDRESS OF THE APPLICATION (D6, as PurchaseApprovalMailer.RequestIssuedAsync): an approval email is a
/// link to the order, and without Settings › Email "Address of the application" there is nothing to link to, so nothing
/// is queued and the action says so. Whether a queued email leaves is the worker's business ("Send emails"; testing never
/// emails real people).
/// </summary>
public sealed class TransferApprovalMailer : ITransferApprovalMailer
{
    internal const string NoAddressWarning =
        "The approvers were not emailed: the address of the application is not set in Settings › Email.";

    internal const string QueueFailedWarning = "The approvers could not be emailed: see the API log.";

    internal const string RequesterNoAddressWarning =
        "The requester was not emailed: the address of the application is not set in Settings › Email.";

    internal const string RequesterQueueFailedWarning = "The requester could not be emailed: see the API log.";

    private const string Font = "font-family:'Segoe UI',Arial,Helvetica,sans-serif;";

    /// <summary>The lines an email shows before "and N more lines".</summary>
    private const int ShownLines = 10;

    private static readonly CultureInfo Numbers = CultureInfo.InvariantCulture;

    private readonly IEmailQueue _queue;
    private readonly IEmailSettingsProvider _emailSettings;
    private readonly TimeProvider _time;
    private readonly ILogger<TransferApprovalMailer> _logger;

    public TransferApprovalMailer(
        IEmailQueue queue, IEmailSettingsProvider emailSettings, TimeProvider time, ILogger<TransferApprovalMailer> logger)
    {
        _queue = queue;
        _emailSettings = emailSettings;
        _time = time;
        _logger = logger;
    }

    /* ── the request ──────────────────────────────────────────────────────────────────────────── */

    public async Task<string?> ApprovalRequestedAsync(
        TransferOrderDto order, IReadOnlyList<TransferApproverDto> approvers, string? requestedByName, int? userId,
        CancellationToken cancellationToken = default)
    {
        var recipients = approvers.Where(a => EmailAddresses.IsValid(a.Email?.Trim())).ToList();
        if (recipients.Count == 0)
        {
            // Nobody to email (no approver, or none with an address): the audit row of the procedure names who was told.
            _logger.LogInformation("Transfer order {TransferOrderId} sent for approval: no approver with an email address.", order.Id);
            return null;
        }

        try
        {
            var baseUrl = (await _emailSettings.GetAsync(cancellationToken)).PublicBaseUrl;
            if (baseUrl is null)
            {
                _logger.LogWarning(
                    "Transfer approval emails not queued (order {TransferOrderId}, {Count} approver(s)): the address of the application is not set in Settings > Email.",
                    order.Id, recipients.Count);
                return NoAddressWarning;
            }

            var subject = $"Approval needed: {Title(order)} ({Route(order)})";
            foreach (var approver in recipients)
            {
                var content = new List<string>
                {
                    Heading("Transfer order for approval"),
                    Paragraph($"Hello {approver.FullName},"),
                    Paragraph($"{requestedByName ?? "A colleague"} asks you to approve this transfer order: {Request(order)}"),
                    LinesTable(order),
                    Buttons(("Open the transfer order", WebRoutes.TransferOrder(baseUrl, order.Id), Blue)),
                    Paragraph("Sign in to approve or reject it.", "#4b5563"),
                };
                await _queue.EnqueueAsync(approver.Email!.Trim(), null, subject, Page(subject, string.Concat(content)), null,
                    EmailCategories.TransferApproval, order.Id, userId, cancellationToken);
            }

            _logger.LogInformation("Transfer order {TransferOrderId} sent for approval: {Count} email(s) queued.", order.Id, recipients.Count);
            return null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Approval emails of transfer order {TransferOrderId} could not be queued.", order.Id);
            return QueueFailedWarning;
        }
    }

    /* ── the decision ─────────────────────────────────────────────────────────────────────────── */

    public Task<string?> ApprovedAsync(
        TransferOrderDto order, TransferRequesterDto? requester, int approverId, int? userId,
        CancellationToken cancellationToken = default)
        => ToRequesterAsync(order, requester, approverId, approved: true, reason: null, userId, cancellationToken);

    public Task<string?> RejectedAsync(
        TransferOrderDto order, TransferRequesterDto? requester, int approverId, string reason, int? userId,
        CancellationToken cancellationToken = default)
        => ToRequesterAsync(order, requester, approverId, approved: false, reason, userId, cancellationToken);

    /// <summary>
    /// The requester learns the outcome - unless they decided themselves (self-approval is allowed, D5: an email to the
    /// person who just clicked tells nobody anything, as the purchase approval), or there was no request.
    /// </summary>
    private async Task<string?> ToRequesterAsync(
        TransferOrderDto order, TransferRequesterDto? requester, int approverId, bool approved, string? reason, int? userId,
        CancellationToken cancellationToken)
    {
        if (requester is null || requester.RequestedById == approverId || !EmailAddresses.IsValid(requester.RequestedByEmail?.Trim()))
        {
            return null;
        }

        try
        {
            var baseUrl = (await _emailSettings.GetAsync(cancellationToken)).PublicBaseUrl;
            if (baseUrl is null)
            {
                _logger.LogWarning(
                    "Transfer approval decision email not queued (order {TransferOrderId}): the address of the application is not set in Settings > Email.",
                    order.Id);
                return RequesterNoAddressWarning;
            }

            var on = Stamp((approved ? order.Approval.ApprovedAtUtc : order.Approval.RejectedAtUtc) ?? _time.GetUtcNow().UtcDateTime);
            var decidedBy = (approved ? order.Approval.ApprovedByName : order.Approval.RejectedByName) ?? "An approver";
            var subject = $"{(approved ? "Approved" : "Rejected")}: {Title(order)} ({Route(order)})";
            var content = new List<string>
            {
                Heading(approved ? "Transfer order approved" : "Transfer order rejected"),
                Paragraph($"Hello {requester.RequestedByName ?? "there"},"),
            };

            if (approved)
            {
                content.Add(Paragraph($"{decidedBy} approved it on {on}. It is released: the goods can be dispatched."));
            }
            else
            {
                content.Add(Paragraph($"{decidedBy} rejected it on {on}: {reason}", "#c92a2a"));
                content.Add(Paragraph("It is a draft again: change it and send it for approval again."));
            }

            content.Add(Buttons(("Open the transfer order", WebRoutes.TransferOrder(baseUrl, order.Id), Blue)));
            content.Add(Paragraph(Request(order), "#4b5563"));
            content.Add(LinesTable(order));

            await _queue.EnqueueAsync(requester.RequestedByEmail!.Trim(), null, subject, Page(subject, string.Concat(content)), null,
                approved ? EmailCategories.TransferApproved : EmailCategories.TransferRejected, order.Id, userId, cancellationToken);
            return null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "The {Decision} email of transfer order {TransferOrderId} could not be queued.",
                approved ? "approval" : "rejection", order.Id);
            return RequesterQueueFailedWarning;
        }
    }

    /* ── shared ───────────────────────────────────────────────────────────────────────────────── */

    /// <summary>"transfer order TRO-BR-003-000012", or "a transfer order" while it has no number (TRO numbered at release).</summary>
    private static string Title(TransferOrderDto order)
        => string.IsNullOrWhiteSpace(order.DocumentNumber) ? "a transfer order" : $"transfer order {order.DocumentNumber}";

    /// <summary>"LKS-01 → LUB-01".</summary>
    private static string Route(TransferOrderDto order) => $"{order.From.Code} → {order.To.Code}";

    /// <summary>
    /// "2 item(s), 84 pcs from Likasi Warehouse (BR-003) to Lubumbashi Warehouse (BR-002), expected 22 Oct 2026." - the
    /// order in one sentence.
    /// </summary>
    private static string Request(TransferOrderDto order)
    {
        var expected = order.ExpectedArrival is { } date ? Date(date.ToDateTime(TimeOnly.MinValue)) : "no date given";
        return $"{order.Totals.ItemCount.ToString("N0", Numbers)} item(s), {order.Totals.OrderedBase.ToString("N0", Numbers)} pcs "
               + $"from {order.From.Name} ({order.From.BranchCode}) to {order.To.Name} ({order.To.BranchCode}), expected {expected}.";
    }

    /// <summary>The first lines of the order (item, unit, ordered), then "and N more lines". No cost: a transfer has none.</summary>
    private static string LinesTable(TransferOrderDto order)
    {
        const string th = "padding:8px 6px;border-bottom:2px solid #e5e7eb;font-size:12px;font-weight:600;color:#6b7280;text-transform:uppercase;";
        const string td = "padding:8px 6px;border-bottom:1px solid #f1f3f5;font-size:13px;color:#1f2937;vertical-align:top;";
        var html = new StringBuilder($"""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 8px 0;border-collapse:collapse;{Font}">
            <tr><td style="{th}text-align:left;">Code</td><td style="{th}text-align:left;">Item</td><td style="{th}text-align:left;">Unit</td><td style="{th}text-align:right;">Ordered</td></tr>
            """);
        foreach (var line in order.Lines.Take(ShownLines))
        {
            var ordered = line.IsBaseUnit || line.PackingFormula <= 1
                ? $"{line.Quantity.ToString("N0", Numbers)}"
                : $"{line.Quantity.ToString("N0", Numbers)} (= {line.OrderedBase.ToString("N0", Numbers)} pcs)";
            html.Append($"""
                <tr><td style="{td}white-space:nowrap;">{E(line.ItemCode)}</td><td style="{td}">{E(line.ItemName)}</td>
                <td style="{td}white-space:nowrap;">{E(line.UnitName)}</td>
                <td style="{td}text-align:right;white-space:nowrap;">{E(ordered)}</td></tr>
                """);
        }

        html.Append("</table>");
        var more = order.Lines.Count - ShownLines;
        if (more > 0)
        {
            html.Append(Paragraph($"and {more} more line{(more == 1 ? string.Empty : "s")}", "#6b7280"));
        }

        return html.ToString();
    }
}
