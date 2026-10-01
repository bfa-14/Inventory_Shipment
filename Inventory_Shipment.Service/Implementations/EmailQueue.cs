using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class EmailQueue : IEmailQueue
{
    private readonly IEmailOutboxRepository _outbox;
    private readonly ILogger<EmailQueue> _logger;

    public EmailQueue(IEmailOutboxRepository outbox, ILogger<EmailQueue> logger)
    {
        _outbox = outbox;
        _logger = logger;
    }

    public async Task<long> EnqueueAsync(
        string to, string? cc, string subject, string htmlBody, EmailAttachment? attachment, string category,
        int? relatedDocumentId = null, int? userId = null, CancellationToken cancellationToken = default)
    {
        var toAddresses = EmailAddresses.Split(to);
        var toList = EmailAddresses.Join(toAddresses)
                     ?? throw new ArgumentException("An email needs at least one recipient.", nameof(to));
        var ccList = EmailAddresses.Join(EmailAddresses.Split(cc)
            .Where(address => !toAddresses.Contains(address, StringComparer.OrdinalIgnoreCase)));

        var id = await _outbox.EnqueueAsync(
            toList, ccList, subject.Trim(), htmlBody, attachment, category, relatedDocumentId, userId, cancellationToken);

        // The subject and category only: never the body, which may hold a personal approval link.
        _logger.LogInformation("Email {EmailId} queued ({Category}): {Subject}", id, category, subject);
        return id;
    }
}
