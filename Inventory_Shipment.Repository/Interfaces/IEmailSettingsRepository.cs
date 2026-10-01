using Inventory_Shipment.Model.DTOs.Messaging;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>messaging.EmailSettings (script 42): the one row of Settings > Email.</summary>
public interface IEmailSettingsRepository
{
    /// <summary>The row WITHOUT the password; null only if the row is missing (script 42 creates it).</summary>
    Task<EmailSettingsRow?> GetAsync(CancellationToken cancellationToken = default);

    /// <summary>The row WITH the encrypted password - for sending only, never for a response.</summary>
    Task<EmailSettingsSendingRow?> GetForSendingAsync(CancellationToken cancellationToken = default);

    /// <exception cref="Exceptions.BusinessRuleException">65025 validation, 65004 changed by someone else.</exception>
    Task<EmailSettingsRow?> SaveAsync(EmailSettingsSave save, CancellationToken cancellationToken = default);

    /// <summary>Records the result of a test; returns the row's new version.</summary>
    Task<byte[]> SetTestResultAsync(bool ok, string? error, CancellationToken cancellationToken = default);
}
