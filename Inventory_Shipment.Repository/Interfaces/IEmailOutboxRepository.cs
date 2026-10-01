using Inventory_Shipment.Model.DTOs.Messaging;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// messaging.EmailOutbox (script 26): every email the application sends is queued here first and sent by
/// the outbox worker, so a mail server that is down never makes a business action fail.
/// </summary>
public interface IEmailOutboxRepository
{
    /// <returns>The new email's id.</returns>
    Task<long> EnqueueAsync(
        string toAddresses, string? ccAddresses, string subject, string bodyHtml, EmailAttachment? attachment,
        string category, int? relatedDocumentId, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Takes up to <paramref name="batchSize"/> due emails for sending (one more attempt counted, a lease of
    /// <paramref name="leaseMinutes"/> so another instance leaves them alone). Returns their ids.
    /// </summary>
    Task<IReadOnlyList<long>> ClaimAsync(int batchSize, int leaseMinutes, CancellationToken cancellationToken = default);

    /// <summary>One email, attachment included; null when it does not exist.</summary>
    Task<OutboxEmail?> GetAsync(long id, CancellationToken cancellationToken = default);

    Task MarkSentAsync(long id, CancellationToken cancellationToken = default);

    /// <summary>Records the error; after <paramref name="maxAttempts"/> attempts the email stays Failed.</summary>
    Task MarkFailedAsync(long id, string error, int maxAttempts, CancellationToken cancellationToken = default);

    /// <summary>A failed (or pending) email goes back to Pending with its attempts reset.</summary>
    /// <exception cref="Exceptions.BusinessRuleException">65006 when the email does not exist.</exception>
    Task RetryAsync(long id, CancellationToken cancellationToken = default);

    Task<(IReadOnlyList<EmailListDto> Items, int TotalCount)> SearchAsync(EmailQuery query, CancellationToken cancellationToken = default);
}
