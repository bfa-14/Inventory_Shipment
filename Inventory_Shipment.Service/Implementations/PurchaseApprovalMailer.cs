using System.Globalization;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.PurchaseEmailHtml;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The emails of the purchase approval cycle, queued in the outbox (the worker sends them while sending is on).
///
/// AN EMAIL NEVER DECIDES ANYTHING: it is queued after the procedure has decided, and a failure to queue one
/// becomes a warning of the action, not an error. TOKENS go into the approval emails only - never into a log
/// line or an answer.
/// </summary>
public sealed class PurchaseApprovalMailer : IPurchaseApprovalMailer
{
    private const string ExcelContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    private const string NoSupplierAddressWarning = "The supplier has no email address: the order was not sent.";

    private readonly IPurchaseDocumentRepository _documents;
    private readonly IPurchaseApprovalRepository _approvals;
    private readonly IEmailQueue _queue;
    private readonly IEmailSettingsProvider _emailSettings;
    private readonly TimeProvider _time;
    private readonly ILogger<PurchaseApprovalMailer> _logger;

    public PurchaseApprovalMailer(
        IPurchaseDocumentRepository documents, IPurchaseApprovalRepository approvals, IEmailQueue queue,
        IEmailSettingsProvider emailSettings, TimeProvider time, ILogger<PurchaseApprovalMailer> logger)
    {
        _documents = documents;
        _approvals = approvals;
        _queue = queue;
        _emailSettings = emailSettings;
        _time = time;
        _logger = logger;
    }

    /* ── requests: sent, sent again, reminders ────────────────────────────────────────────────── */

    public async Task RequestIssuedAsync(
        IReadOnlyList<ApprovalLinkRow> rows, ApprovalRequestKind kind, int? userId, CancellationToken cancellationToken = default)
    {
        var baseUrl = (await _emailSettings.GetAsync(cancellationToken)).PublicBaseUrl;
        if (baseUrl is null)
        {
            _logger.LogWarning("Approval emails not queued ({Kind}, {Count} approver(s)): the address of the application is not set in Settings > Email.",
                kind, rows.Count);
            return;
        }

        var linkValidHours = (await _approvals.GetSettingsAsync(cancellationToken)).Settings.LinkValidHours;
        var queued = 0;
        foreach (var order in rows.Where(r => r.SendEmail && EmailAddresses.IsValid(r.Email)).GroupBy(r => r.PurchaseDocumentId))
        {
            try
            {
                var document = await _documents.GetAsync(order.Key, cancellationToken);
                if (document is null)
                {
                    continue;
                }

                var (state, _) = await _approvals.GetStateAsync(order.Key, userId ?? 0, cancellationToken);
                foreach (var row in order)
                {
                    var waitingSince = row.WaitingSinceUtc ?? state.RequestedAtUtc;
                    var (subject, html) = RequestEmail(document, row, kind, state.RequestedByName, waitingSince, linkValidHours, baseUrl);
                    await _queue.EnqueueAsync(row.Email!, null, subject, html, null,
                        kind == ApprovalRequestKind.Reminder ? EmailCategories.PurchaseApprovalReminder : EmailCategories.PurchaseApproval,
                        document.Id, userId, cancellationToken);
                    queued++;
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Approval emails of purchase order {DocumentId} could not be queued ({Kind}).", order.Key, kind);
            }
        }

        _logger.LogInformation("Approval {Kind}: {Queued} email(s) queued for {Orders} order(s), {Approvers} approver(s).",
            kind, queued, rows.Select(r => r.PurchaseDocumentId).Distinct().Count(), rows.Count);
    }

    private (string Subject, string Html) RequestEmail(
        PurchaseDocumentDto order, ApprovalLinkRow row, ApprovalRequestKind kind, string? requestedBy, DateTime? waitingSince,
        int linkValidHours, string baseUrl)
    {
        var byEmail = string.Equals(row.Channel, "Email", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(row.Token);
        var amount = $"{Money(order.TotalAmount, order.DecimalPlaces)} {order.CurrencyCode}";
        var subject = (kind == ApprovalRequestKind.Reminder ? "Reminder: " : string.Empty)
                      + (byEmail ? "Approval needed: " : "Approval needed in the application: ")
                      + $"purchase order for {order.SupplierName} - {amount}";
        var orderUrl = WebRoutes.PurchaseOrder(baseUrl, order.Id);

        var content = new List<string>
        {
            Heading(byEmail ? "Purchase order for approval" : "Approval needed in the application"),
            Paragraph($"Hello {row.FullName},"),
            Paragraph($"{requestedBy ?? "A colleague"} asks you to approve this purchase order for {order.SupplierName} ({amount})."),
        };

        if (kind == ApprovalRequestKind.Reminder && waitingSince is { } since)
        {
            var hours = (int)Math.Floor((_time.GetUtcNow().UtcDateTime - since).TotalHours);
            content.Add(Paragraph($"Waiting for your approval since {Stamp(since)} ({hours} hour{(hours == 1 ? string.Empty : "s")}).", "#b45309"));
        }

        content.Add(Summary(order, requestedBy));
        content.Add(Lines(order));

        if (byEmail)
        {
            var approveUrl = WebRoutes.PurchaseApproval(baseUrl, row.Token!, approve: true);
            var rejectUrl = WebRoutes.PurchaseApproval(baseUrl, row.Token!, approve: false);
            content.Add(Buttons(("Review and approve", approveUrl, Green), ("Reject...", rejectUrl, Red)));
            content.Add(ParagraphHtml("If the buttons do not work, open this link: " + Link(approveUrl), "#4b5563"));
            content.Add(Paragraph(
                $"This link is personal, valid for {linkValidHours} hours and works once. Nothing is approved until you click Approve on the page that opens.",
                "#6b7280"));
            if (row.CanApproveInApp)
            {
                content.Add(ParagraphHtml("You can also approve it in the application: " + Link(orderUrl), "#4b5563"));
            }
        }
        else
        {
            content.Add(Buttons(("Open the order", orderUrl, Blue)));
            content.Add(Paragraph("Sign in to approve or reject it.", "#4b5563"));
        }

        return (subject, Page(subject, string.Concat(content)));
    }

    /* ── after a decision ─────────────────────────────────────────────────────────────────────── */

    public async Task<ApprovalFollowUp> DecidedAsync(ApprovalDecisionRow decision, int? userId, CancellationToken cancellationToken = default)
    {
        try
        {
            var order = await _documents.GetAsync(decision.DocumentId, cancellationToken);
            if (order is null)
            {
                return ApprovalFollowUp.Nothing;
            }

            var baseUrl = (await _emailSettings.GetAsync(cancellationToken)).PublicBaseUrl;
            return decision.Approved
                ? await ApprovedAsync(order, decision, baseUrl, userId, cancellationToken)
                : await RejectedAsync(order, decision, baseUrl, userId, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Follow-up emails of purchase order {DocumentId} could not be queued.", decision.DocumentId);
            return new ApprovalFollowUp { Warnings = ["The follow-up emails could not be queued: see the Email log and the API log."] };
        }
    }

    public async Task<ApprovalFollowUp> DecidedAsync(int purchaseDocumentId, int? userId, CancellationToken cancellationToken = default)
    {
        try
        {
            var order = await _documents.GetAsync(purchaseDocumentId, cancellationToken);
            if (order is null)
            {
                return ApprovalFollowUp.Nothing;
            }

            // Posted without approval: the supplier email and the copies only - nobody asked, nobody to tell.
            var settings = await _approvals.GetSettingsAsync(cancellationToken);
            var owners = settings.Users
                .Where(u => (u.Roles ?? string.Empty).Split(", ").Contains("Owner") && EmailAddresses.IsValid(u.Email))
                .Select(u => u.Email!);
            return await SendApprovedOrderAsync(order, settings.Settings.EmailSupplierOnApproval, order.SupplierEmail,
                settings.Settings.CopyToOwners ? string.Join(';', owners) : null, settings.Settings.CopyToEmails, null, userId, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Supplier email of purchase order {DocumentId} could not be queued.", purchaseDocumentId);
            return new ApprovalFollowUp { Warnings = ["The supplier email could not be queued: see the Email log and the API log."] };
        }
    }

    private async Task<ApprovalFollowUp> ApprovedAsync(
        PurchaseDocumentDto order, ApprovalDecisionRow decision, string? baseUrl, int? userId, CancellationToken cancellationToken)
    {
        var followUp = await SendApprovedOrderAsync(order, decision.EmailSupplierOnApproval, decision.SupplierEmail,
            decision.CopyToOwners ? decision.OwnerEmails : null, decision.CopyToEmails, decision.RequestedByName, userId, cancellationToken);

        // The requester learns the outcome - unless they decided themselves, or there was no request.
        if (!decision.Direct && decision.RequestedBy != decision.DecidedBy && EmailAddresses.IsValid(decision.RequestedByEmail))
        {
            var how = ChannelText(decision.Channel);
            var supplierLine = followUp.SupplierEmailed switch
            {
                true => $"It was emailed to the supplier at {decision.SupplierEmail}.",
                false => "It was NOT sent to the supplier: the supplier has no email address.",
                _ => "It was not emailed to the supplier (switched off in Settings > Purchase approval).",
            };
            var subject = $"Approved: purchase order {order.DocumentNumber} for {order.SupplierName}";
            var content = new List<string>
            {
                Heading("Purchase order approved"),
                Paragraph($"Approved by {decision.DecidedByName} ({how}) on {Stamp(_time.GetUtcNow().UtcDateTime)}."),
                Paragraph(supplierLine, followUp.SupplierEmailed == false ? "#c92a2a" : "#1f2937"),
            };
            if (baseUrl is not null)
            {
                content.Add(Buttons(("Open the order", WebRoutes.PurchaseOrder(baseUrl, order.Id), Blue)));
            }

            content.Add(Summary(order, decision.RequestedByName));
            content.Add(Lines(order));
            await _queue.EnqueueAsync(decision.RequestedByEmail!, null, subject, Page(subject, string.Concat(content)), null,
                EmailCategories.PurchaseOrderApproved, order.Id, userId, cancellationToken);
        }

        return followUp;
    }

    private async Task<ApprovalFollowUp> RejectedAsync(
        PurchaseDocumentDto order, ApprovalDecisionRow decision, string? baseUrl, int? userId, CancellationToken cancellationToken)
    {
        var to = new[] { decision.RequestedByEmail, decision.CreatorEmail }
            .Where(address => EmailAddresses.IsValid(address))
            .Select(address => address!.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (to.Count == 0)
        {
            return ApprovalFollowUp.Nothing;
        }

        var subject = $"Rejected: purchase order for {order.SupplierName}";
        var content = new List<string>
        {
            Heading("Purchase order rejected"),
            Paragraph($"Rejected by {decision.DecidedByName} ({ChannelText(decision.Channel)}) on {Stamp(_time.GetUtcNow().UtcDateTime)}."),
            ParagraphHtml($"<strong>Reason:</strong> {E(decision.DecisionNote)}", "#c92a2a"),
            Paragraph("The order is a draft again: change it and send it for approval again."),
        };
        if (baseUrl is not null)
        {
            content.Add(Buttons(("Open the order", WebRoutes.PurchaseOrder(baseUrl, order.Id), Blue)));
        }

        content.Add(Summary(order, decision.RequestedByName));
        content.Add(Lines(order));
        await _queue.EnqueueAsync(string.Join(';', to), null, subject, Page(subject, string.Concat(content)), null,
            EmailCategories.PurchaseOrderRejected, order.Id, userId, cancellationToken);
        return ApprovalFollowUp.Nothing;
    }

    /// <summary>The supplier email (when on) with the Excel file, and the copies to the Owner users and the copy addresses.</summary>
    private async Task<ApprovalFollowUp> SendApprovedOrderAsync(
        PurchaseDocumentDto order, bool emailSupplier, string? supplierEmail, string? ownerEmails, string? copyToEmails,
        string? requestedBy, int? userId, CancellationToken cancellationToken)
    {
        bool? supplierEmailed = null;
        var warnings = new List<string>();
        var attachment = Excel(order);
        var (subject, html) = SupplierEmail(order, requestedBy, null);

        if (emailSupplier)
        {
            if (EmailAddresses.IsValid(supplierEmail?.Trim()))
            {
                var address = supplierEmail!.Trim();
                await _queue.EnqueueAsync(address, null, subject, html, attachment, EmailCategories.PurchaseOrderToSupplier, order.Id, userId, cancellationToken);
                await _approvals.LogSupplierEmailAsync(order.Id, true, address, userId, cancellationToken);
                supplierEmailed = true;
            }
            else
            {
                await _approvals.LogSupplierEmailAsync(order.Id, false, null, userId, cancellationToken);
                supplierEmailed = false;
                warnings.Add(NoSupplierAddressWarning);
            }
        }

        var copies = EmailAddresses.Split(ownerEmails).Concat(EmailAddresses.Split(copyToEmails))
            .Where(EmailAddresses.IsValid)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (copies.Count > 0)
        {
            var note = supplierEmailed switch
            {
                true => $"Copy of the purchase order emailed to {order.SupplierName} at {supplierEmail!.Trim()}.",
                false => $"Copy of the purchase order. It was NOT sent to {order.SupplierName}: the supplier has no email address.",
                _ => "Copy of the approved purchase order (not emailed to the supplier).",
            };
            var (_, copyHtml) = SupplierEmail(order, requestedBy, null, note);
            await _queue.EnqueueAsync(string.Join(';', copies), null, "Copy: " + subject, copyHtml, attachment,
                EmailCategories.PurchaseOrderApproved, order.Id, userId, cancellationToken);
        }

        return new ApprovalFollowUp { SupplierEmailed = supplierEmailed, Warnings = warnings };
    }

    /* ── to the supplier on request ───────────────────────────────────────────────────────────── */

    public async Task SendToSupplierAsync(
        int purchaseDocumentId, string to, string? cc, string? message, int userId, CancellationToken cancellationToken = default)
    {
        var order = await _documents.GetAsync(purchaseDocumentId, cancellationToken)
                    ?? throw new InvalidOperationException($"Purchase order {purchaseDocumentId} not found.");

        var (subject, html) = SupplierEmail(order, null, message);
        await _queue.EnqueueAsync(to, cc, subject, html, Excel(order), EmailCategories.PurchaseOrderToSupplier, order.Id, userId, cancellationToken);
        var recipients = EmailAddresses.Join(EmailAddresses.Split(to).Concat(EmailAddresses.Split(cc)));
        await _approvals.LogSupplierEmailAsync(order.Id, true, recipients, userId, cancellationToken);
    }

    /* ── shared ───────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The supplier's email: the typed message first, the order, the Excel file attached.</summary>
    private static (string Subject, string Html) SupplierEmail(PurchaseDocumentDto order, string? requestedBy, string? message, string? internalNote = null)
    {
        var subject = $"Purchase order {order.DocumentNumber} - {CompanyName}";
        var content = new List<string>();
        if (!string.IsNullOrWhiteSpace(internalNote))
        {
            content.Add(Paragraph(internalNote, "#6b7280"));
        }

        content.Add(Heading($"Purchase order {order.DocumentNumber}"));
        if (!string.IsNullOrWhiteSpace(message))
        {
            foreach (var paragraph in message.Trim().Split('\n').Where(line => line.Trim().Length > 0))
            {
                content.Add(Paragraph(paragraph.Trim()));
            }
        }

        content.Add(Paragraph($"Dear {order.SupplierName},"));
        content.Add(Paragraph($"Please find attached our purchase order {order.DocumentNumber} ({FileName(order)}). Kindly confirm its receipt and the expected shipping date."));
        content.Add(Summary(order, requestedBy));
        content.Add(Lines(order));
        content.Add(Paragraph($"Purchasing - {CompanyName}", "#4b5563"));
        return (subject, Page(subject, string.Concat(content)));
    }

    private static EmailAttachment Excel(PurchaseDocumentDto order)
        => new(FileName(order), ExcelContentType, PurchaseDocumentService.BuildWorkbook(order));

    /// <summary>"PO-{number}.xlsx" - without doubling the prefix of a number that already starts with "PO-".</summary>
    private static string FileName(PurchaseDocumentDto order)
    {
        var number = order.DocumentNumber ?? order.Id.ToString(CultureInfo.InvariantCulture);
        return (number.StartsWith("PO-", StringComparison.OrdinalIgnoreCase) ? number : "PO-" + number) + ".xlsx";
    }

    private static string ChannelText(string? channel)
        => string.Equals(channel, "Email", StringComparison.OrdinalIgnoreCase) ? "by email" : "in the app";
}
