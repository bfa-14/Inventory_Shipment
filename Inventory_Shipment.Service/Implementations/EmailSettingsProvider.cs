using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The settings the application sends with, read from messaging.EmailSettings and cached for 30 seconds.
///
/// A SINGLETON with its own scope per read: the worker and every request share one cache, and the
/// repository it reads through is scoped like every other.
///
/// A PASSWORD THAT CAN NO LONGER BE DECRYPTED (the Data Protection keys were lost or the database moved
/// to another server) does not stop the API: the settings say <see cref="EffectiveEmailSettings.PasswordUnreadable"/>,
/// the page asks for the password again, and the problem is logged once per saved value - not every 30 seconds.
/// </summary>
public sealed class EmailSettingsProvider : IEmailSettingsProvider
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(30);

    private readonly IServiceScopeFactory _scopes;
    private readonly ISecretProtector _protector;
    private readonly IOptionsMonitor<AppOptions> _app;
    private readonly TimeProvider _time;
    private readonly ILogger<EmailSettingsProvider> _logger;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private Cached? _cached;
    private string? _reportedUnreadable;

    private sealed record Cached(EffectiveEmailSettings Settings, DateTimeOffset ReadAt);

    public EmailSettingsProvider(
        IServiceScopeFactory scopes, ISecretProtector protector, IOptionsMonitor<AppOptions> app, TimeProvider time,
        ILogger<EmailSettingsProvider> logger)
    {
        _scopes = scopes;
        _protector = protector;
        _app = app;
        _time = time;
        _logger = logger;
    }

    public async Task<EffectiveEmailSettings> GetAsync(CancellationToken cancellationToken = default)
    {
        var cached = Volatile.Read(ref _cached);
        if (cached is not null && _time.GetUtcNow() - cached.ReadAt < CacheFor)
        {
            return cached.Settings;
        }

        await _gate.WaitAsync(cancellationToken);
        try
        {
            cached = Volatile.Read(ref _cached);
            if (cached is not null && _time.GetUtcNow() - cached.ReadAt < CacheFor)
            {
                return cached.Settings;
            }

            var settings = await ReadAsync(cancellationToken);
            Volatile.Write(ref _cached, new Cached(settings, _time.GetUtcNow()));
            return settings;
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Invalidate() => Volatile.Write(ref _cached, null);

    private async Task<EffectiveEmailSettings> ReadAsync(CancellationToken cancellationToken)
    {
        using var scope = _scopes.CreateScope();
        var row = await scope.ServiceProvider.GetRequiredService<IEmailSettingsRepository>().GetForSendingAsync(cancellationToken);
        var configuredUrl = NormalizeUrl(_app.CurrentValue.PublicBaseUrl);

        // Never saved from the page: nothing is sent, the links use the configuration's address.
        if (row?.UpdatedAtUtc is null)
        {
            return new EffectiveEmailSettings { IsSaved = false, SendingEnabled = false, PublicBaseUrl = configuredUrl };
        }

        string? password = null;
        var unreadable = false;
        if (!string.IsNullOrEmpty(row.SmtpPasswordProtected))
        {
            if (_protector.TryUnprotect(row.SmtpPasswordProtected, out var plain))
            {
                password = plain;
            }
            else
            {
                unreadable = true;
                if (!string.Equals(_reportedUnreadable, row.SmtpPasswordProtected, StringComparison.Ordinal))
                {
                    _reportedUnreadable = row.SmtpPasswordProtected;
                    _logger.LogWarning("The saved SMTP password can no longer be read: type it again in Settings > Email.");
                }
            }
        }

        return new EffectiveEmailSettings
        {
            IsSaved = true,
            SendingEnabled = row.SendingEnabled,
            Host = row.SmtpHost,
            Port = row.SmtpPort,
            Security = Enum.IsDefined(typeof(SmtpSecurity), (int)row.SmtpSecurity) ? (SmtpSecurity)row.SmtpSecurity : SmtpSecurity.StartTls,
            UserName = row.SmtpUserName,
            Password = password,
            FromAddress = row.FromAddress,
            FromName = row.FromName,
            ReplyTo = row.ReplyToAddress,
            PublicBaseUrl = NormalizeUrl(row.PublicBaseUrl) ?? configuredUrl,
            PasswordUnreadable = unreadable,
        };
    }

    /// <summary>"https://erp.example.com/" -> "https://erp.example.com"; empty -> null.</summary>
    internal static string? NormalizeUrl(string? url)
    {
        var trimmed = url?.Trim().TrimEnd('/');
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
