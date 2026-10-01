using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Configuration;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class SettingService : ISettingService
{
    private readonly ISettingRepository _settings;
    private readonly ILogger<SettingService> _logger;

    public SettingService(ISettingRepository settings, ILogger<SettingService> logger)
    {
        _settings = settings;
        _logger = logger;
    }

    public async Task<Result<IReadOnlyList<SettingDto>>> ListAsync(CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<SettingDto>>.Success(await _settings.ListAsync(onlyPublic: false, cancellationToken));

    public async Task<Result<IReadOnlyList<SettingLookupDto>>> LookupAsync(CancellationToken cancellationToken = default)
    {
        var rows = await _settings.ListAsync(onlyPublic: true, cancellationToken);
        IReadOnlyList<SettingLookupDto> lookup = rows
            .Select(row => new SettingLookupDto { SettingKey = row.SettingKey, ValueType = row.ValueType, Value = row.Value })
            .ToList();

        return Result<IReadOnlyList<SettingLookupDto>>.Success(lookup);
    }

    public async Task<Result<SettingDto>> SaveAsync(
        string settingKey, SaveSettingRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Configuration.SettingsManage))
        {
            return Forbidden<SettingDto>();
        }

        try
        {
            await _settings.SaveAsync(settingKey, request.Value, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<SettingDto>(ex);
        }

        _logger.LogInformation("Setting {SettingKey} saved by user {UserId}", settingKey, userId);
        return await ReadAsync(settingKey, cancellationToken);
    }

    public async Task<Result<SettingDto>> ResetAsync(
        string settingKey, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Configuration.SettingsManage))
        {
            return Forbidden<SettingDto>();
        }

        try
        {
            await _settings.ResetAsync(settingKey, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<SettingDto>(ex);
        }

        _logger.LogInformation("Setting {SettingKey} reset to its default by user {UserId}", settingKey, userId);
        return await ReadAsync(settingKey, cancellationToken);
    }

    public Task<string?> GetValueAsync(string settingKey, CancellationToken cancellationToken = default)
        => _settings.GetValueAsync(settingKey, cancellationToken);

    public async Task<bool> GetBoolAsync(string settingKey, CancellationToken cancellationToken = default)
    {
        var value = await _settings.GetValueAsync(settingKey, cancellationToken);
        return value is not null && (value.Equals("true", StringComparison.OrdinalIgnoreCase)
                                     || value == "1"
                                     || value.Equals("yes", StringComparison.OrdinalIgnoreCase));
    }

    private async Task<Result<SettingDto>> ReadAsync(string settingKey, CancellationToken cancellationToken)
    {
        var all = await _settings.ListAsync(onlyPublic: false, cancellationToken);
        var setting = all.FirstOrDefault(s => s.SettingKey == settingKey);
        return setting is null
            ? Result<SettingDto>.Failure(ErrorType.NotFound, "Setting not found.", "NOT_FOUND")
            : Result<SettingDto>.Success(setting);
    }

    private static Result<T> Failure<T>(BusinessRuleException exception)
        => exception.Number == SqlErrors.SettingNotFound
            ? Result<T>.Failure(ErrorType.NotFound, exception.Message, "NOT_FOUND")
            : Result<T>.Failure(ErrorType.Validation, exception.Message, "VALIDATION");

    private static Result<T> Forbidden<T>()
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {Permissions.Configuration.SettingsManage} permission.", "FORBIDDEN");
}
