using Inventory_Shipment.Model.DTOs.Configuration;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>Global settings (configuration.Setting*): the view, the writes, and the value read by other modules.</summary>
public interface ISettingRepository
{
    /// <summary>Every setting with its effective value; <paramref name="onlyPublic"/> keeps those any signed-in user may read.</summary>
    Task<IReadOnlyList<SettingDto>> ListAsync(bool onlyPublic, CancellationToken cancellationToken = default);

    /// <summary>The effective value of one setting as text, or null when no such setting is defined.</summary>
    Task<string?> GetValueAsync(string settingKey, CancellationToken cancellationToken = default);

    /// <exception cref="Exceptions.BusinessRuleException">72000 when the value does not fit the type, 72006 for an unknown key.</exception>
    Task SaveAsync(string settingKey, string? value, int userId, CancellationToken cancellationToken = default);

    Task ResetAsync(string settingKey, int userId, CancellationToken cancellationToken = default);
}
