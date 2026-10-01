using Inventory_Shipment.Model.DTOs.Messaging;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// The one way to send an email: it is written to the outbox and sent by the outbox worker, with retries.
/// A business action never waits for the mail server, and an email is never lost because the server is down.
/// </summary>
public interface IEmailQueue
{
    /// <param name="to">One or several addresses, separated by ";" or ",".</param>
    /// <param name="category">One of <see cref="EmailCategories"/>.</param>
    /// <returns>The queued email's id.</returns>
    Task<long> EnqueueAsync(
        string to, string? cc, string subject, string htmlBody, EmailAttachment? attachment, string category,
        int? relatedDocumentId = null, int? userId = null, CancellationToken cancellationToken = default);
}
