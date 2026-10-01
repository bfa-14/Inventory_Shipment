using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Configuration;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Global settings: ONE pattern for every system-wide switch. The Settings page edits them (manage
/// permission); any signed-in screen reads the public ones through the lookup; services read the value
/// they need with <see cref="GetBoolAsync"/> and its siblings, so no module keeps a switch of its own.
/// </summary>
public interface ISettingService
{
    /// <summary>Every setting, for the Settings page.</summary>
    Task<Result<IReadOnlyList<SettingDto>>> ListAsync(CancellationToken cancellationToken = default);

    /// <summary>The public settings' values, for any signed-in user.</summary>
    Task<Result<IReadOnlyList<SettingLookupDto>>> LookupAsync(CancellationToken cancellationToken = default);

    Task<Result<SettingDto>> SaveAsync(
        string settingKey, SaveSettingRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Drops the administrator's choice; the default applies again.</summary>
    Task<Result<SettingDto>> ResetAsync(
        string settingKey, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The effective value as text; null when the key is not a defined setting.</summary>
    Task<string?> GetValueAsync(string settingKey, CancellationToken cancellationToken = default);

    /// <summary>True / 1 / yes read as true. An undefined key reads as false.</summary>
    Task<bool> GetBoolAsync(string settingKey, CancellationToken cancellationToken = default);
}
