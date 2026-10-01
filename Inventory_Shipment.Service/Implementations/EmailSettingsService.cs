using System.Diagnostics;
using System.Globalization;
using System.Net;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Settings > Email. THE PASSWORD GOES ONE WAY: typed on the page, encrypted here, stored encrypted; it is
/// decrypted only by <see cref="IEmailSettingsProvider"/> to send, and never answered, logged or put in a
/// message. A test may use a password typed on the page without saving it.
/// </summary>
public sealed class EmailSettingsService : IEmailSettingsService
{
    private const string TestSubject = "Test email from Inventory & Shipment";

    private readonly IEmailSettingsRepository _settings;
    private readonly IEmailSettingsProvider _provider;
    private readonly ISecretProtector _protector;
    private readonly IEmailSender _sender;
    private readonly IUserRepository _users;
    private readonly TimeProvider _time;
    private readonly ILogger<EmailSettingsService> _logger;

    public EmailSettingsService(
        IEmailSettingsRepository settings, IEmailSettingsProvider provider, ISecretProtector protector, IEmailSender sender,
        IUserRepository users, TimeProvider time, ILogger<EmailSettingsService> logger)
    {
        _settings = settings;
        _provider = provider;
        _protector = protector;
        _sender = sender;
        _users = users;
        _time = time;
        _logger = logger;
    }

    public async Task<Result<EmailSettingsDto>> GetAsync(CancellationToken cancellationToken = default)
    {
        var row = await _settings.GetAsync(cancellationToken);
        var effective = await _provider.GetAsync(cancellationToken);
        return Result<EmailSettingsDto>.Success(ToDto(row, effective));
    }

    public async Task<Result<EmailSettingsDto>> SaveAsync(
        SaveEmailSettingsRequest request, int userId, CancellationToken cancellationToken = default)
    {
        // 0 keep, 1 replace (typed), 2 remove.
        byte action = request.RemovePassword ? (byte)2 : string.IsNullOrEmpty(request.Password) ? (byte)0 : (byte)1;
        var protectedPassword = action == 1 ? _protector.Protect(request.Password!) : null;

        EmailSettingsRow? row;
        try
        {
            row = await _settings.SaveAsync(new EmailSettingsSave(
                request.SendingEnabled, request.SmtpHost, request.SmtpPort, request.SmtpSecurity, request.SmtpUserName,
                action, protectedPassword, request.FromAddress, request.FromName, request.ReplyToAddress, request.PublicBaseUrl,
                ToRowVersion(request.RowVersion), userId), cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<EmailSettingsDto>(ex);
        }

        _provider.Invalidate();
        _logger.LogInformation(
            "Email settings saved by user {UserId}: sending {Sending}, server {Host}:{Port}, password {PasswordAction}",
            userId, request.SendingEnabled ? "on" : "off", request.SmtpHost, request.SmtpPort,
            action switch { 1 => "replaced", 2 => "removed", _ => "kept" });

        var effective = await _provider.GetAsync(cancellationToken);
        return Result<EmailSettingsDto>.Success(ToDto(row, effective));
    }

    public async Task<Result<EmailTestResultDto>> TestAsync(
        TestEmailSettingsRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var to = request.To?.Trim();
        if (!EmailAddresses.IsValid(to))
        {
            return Result<EmailTestResultDto>.Failure(ErrorType.Validation, "Enter a valid email address to send the test to.", "VALIDATION");
        }

        var saved = await _provider.GetAsync(cancellationToken);
        var settings = request.Values is null ? saved : FromValues(request.Values, saved);

        var user = await _users.GetByIdAsync(userId, cancellationToken);
        var sentBy = user?.FullName ?? $"user {userId}";
        var at = _time.GetUtcNow().ToString("d MMM yyyy HH:mm 'UTC'", CultureInfo.InvariantCulture);
        var html = "<p style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937\">"
                   + $"If you can read this, the email settings work. Sent by {WebUtility.HtmlEncode(sentBy)} on {at}.</p>";

        var watch = Stopwatch.StartNew();
        string? error = null;
        try
        {
            await _sender.SendAsync(new OutgoingEmail(to!, null, TestSubject, html), settings, cancellationToken);
        }
        catch (EmailSendException ex)
        {
            error = ex.Message;
        }

        watch.Stop();
        var rowVersion = await _settings.SetTestResultAsync(error is null, error, cancellationToken);
        _logger.LogInformation("Test email by user {UserId} to {To} through {Host}:{Port}: {Outcome} in {Ms} ms",
            userId, to, settings.Host, settings.Port, error is null ? "sent" : "failed - " + error, watch.ElapsedMilliseconds);

        return Result<EmailTestResultDto>.Success(new EmailTestResultDto
        {
            Ok = error is null,
            Error = error,
            DurationMs = watch.ElapsedMilliseconds,
            RowVersion = rowVersion,
        });
    }

    /// <summary>The unsaved form; the password typed there, else the saved one.</summary>
    private static EffectiveEmailSettings FromValues(EmailSettingsValues values, EffectiveEmailSettings saved)
        => new()
        {
            IsSaved = saved.IsSaved,
            SendingEnabled = values.SendingEnabled,
            Host = values.SmtpHost?.Trim(),
            Port = values.SmtpPort,
            Security = values.SmtpSecurity switch
            {
                SmtpSecurityModes.None => SmtpSecurity.None,
                SmtpSecurityModes.SslOnConnect => SmtpSecurity.SslOnConnect,
                _ => SmtpSecurity.StartTls,
            },
            UserName = string.IsNullOrWhiteSpace(values.SmtpUserName) ? null : values.SmtpUserName.Trim(),
            Password = string.IsNullOrEmpty(values.Password) ? saved.Password : values.Password,
            FromAddress = values.FromAddress?.Trim(),
            FromName = string.IsNullOrWhiteSpace(values.FromName) ? null : values.FromName.Trim(),
            ReplyTo = string.IsNullOrWhiteSpace(values.ReplyToAddress) ? null : values.ReplyToAddress.Trim(),
            PublicBaseUrl = EmailSettingsProvider.NormalizeUrl(values.PublicBaseUrl) ?? saved.PublicBaseUrl,
        };

    private static EmailSettingsDto ToDto(EmailSettingsRow? row, EffectiveEmailSettings effective)
        => row is null
            ? new EmailSettingsDto { SmtpPort = 587, SmtpSecurity = SmtpSecurityModes.StartTls, EffectivePublicBaseUrl = effective.PublicBaseUrl }
            : new EmailSettingsDto
            {
                IsSaved = row.IsSaved,
                SendingEnabled = row.SendingEnabled,
                SmtpHost = row.SmtpHost,
                SmtpPort = row.SmtpPort,
                SmtpSecurity = row.SmtpSecurity,
                SmtpUserName = row.SmtpUserName,
                HasPassword = row.HasPassword,
                PasswordUnreadable = row.HasPassword && effective.PasswordUnreadable,
                FromAddress = row.FromAddress,
                FromName = row.FromName,
                ReplyToAddress = row.ReplyToAddress,
                PublicBaseUrl = row.PublicBaseUrl,
                EffectivePublicBaseUrl = effective.PublicBaseUrl,
                LastTestAtUtc = row.LastTestAtUtc,
                LastTestOk = row.LastTestOk,
                LastTestError = row.LastTestError,
                UpdatedAtUtc = row.UpdatedAtUtc,
                UpdatedByName = row.UpdatedByName,
                RowVersion = row.RowVersion,
            };

    private static byte[]? ToRowVersion(string? value)
        => !string.IsNullOrWhiteSpace(value) && Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;

    private static Result<T> Failure<T>(BusinessRuleException exception)
        => exception.Number switch
        {
            SqlErrors.PurchaseDocumentConcurrency => Result<T>.Failure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
            SqlErrors.EmailSettingsValidation => Result<T>.Failure(ErrorType.Validation, exception.Message, "VALIDATION"),
            _ => Result<T>.Failure(ErrorType.Validation, exception.Message, "VALIDATION"),
        };
}
