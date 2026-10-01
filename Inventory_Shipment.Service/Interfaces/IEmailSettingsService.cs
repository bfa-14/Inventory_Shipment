using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Messaging;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>Settings > Email: the mail server, the sender, the address of the application, and a test.</summary>
public interface IEmailSettingsService
{
    Task<Result<EmailSettingsDto>> GetAsync(CancellationToken cancellationToken = default);

    /// <summary>400 VALIDATION (65025) with the procedure's message; 409 CONCURRENCY when the row changed meanwhile.</summary>
    Task<Result<EmailSettingsDto>> SaveAsync(SaveEmailSettingsRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Sends ONE email at once with the values given (the unsaved form) or else the saved settings, records
    /// the result and answers it - a failure is a result (ok false), not an error. Works while sending is off.
    /// </summary>
    Task<Result<EmailTestResultDto>> TestAsync(TestEmailSettingsRequest request, int userId, CancellationToken cancellationToken = default);
}

/// <summary>Settings > Email log: every email the application queued, its status and its HTML.</summary>
public interface IEmailLogService
{
    Task<Result<PagedResult<EmailListDto>>> SearchAsync(EmailQuery query, CancellationToken cancellationToken = default);

    Task<Result<EmailDto>> GetAsync(long id, CancellationToken cancellationToken = default);

    /// <summary>Back to Pending with its attempts reset; the worker sends it at its next cycle.</summary>
    Task<Result<EmailDto>> RetryAsync(long id, CancellationToken cancellationToken = default);

    /// <summary>Queues a short test email to the signed-in user's own address (400 when the user has none).</summary>
    Task<Result<EmailDto>> QueueTestAsync(int userId, CancellationToken cancellationToken = default);
}
