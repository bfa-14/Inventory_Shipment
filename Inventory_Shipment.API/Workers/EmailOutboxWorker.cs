using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.API.Workers;

/// <summary>
/// Sends the queued emails: every 30 seconds, while sending is on, it claims up to 10 due emails and sends
/// them one by one; each is marked Sent, or Failed with the sender's readable error (retried later, given up
/// after 5 attempts).
///
/// SENDING OFF = NOTHING LEAVES THE SERVER: the emails stay Pending, readable in the Email log, and are sent
/// once sending is switched on. The worker says so when the state changes, not every cycle.
///
/// IT NEVER STOPS: an error in one cycle is logged and the next cycle runs. It logs counts, never a
/// password, never a body (an approval email holds a personal link).
/// </summary>
public sealed class EmailOutboxWorker : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(30);
    private const int BatchSize = 10;
    private const int LeaseMinutes = 5;
    private const int MaxAttempts = 5;

    private readonly IServiceScopeFactory _scopes;
    private readonly IEmailSettingsProvider _settings;
    private readonly IEmailSender _sender;
    private readonly ILogger<EmailOutboxWorker> _logger;
    private string? _lastState;

    public EmailOutboxWorker(
        IServiceScopeFactory scopes, IEmailSettingsProvider settings, IEmailSender sender, ILogger<EmailOutboxWorker> logger)
    {
        _scopes = scopes;
        _settings = settings;
        _sender = sender;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
        do
        {
            try
            {
                await RunOnceAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Email outbox: the cycle failed; the next one runs in {Seconds} s.", Interval.TotalSeconds);
            }
        }
        while (await WaitAsync(timer, stoppingToken));
    }

    private static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken stoppingToken)
    {
        try
        {
            return await timer.WaitForNextTickAsync(stoppingToken);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    private async Task RunOnceAsync(CancellationToken stoppingToken)
    {
        var settings = await _settings.GetAsync(stoppingToken);
        var state = !settings.SendingEnabled ? "off"
            : settings.PasswordUnreadable ? "unreadable"
            : "on";
        if (state != _lastState)
        {
            _lastState = state;
            switch (state)
            {
                case "off":
                    _logger.LogInformation("Email sending is off: nothing to send, queued emails stay Pending in the Email log.");
                    break;
                case "unreadable":
                    _logger.LogWarning("Email sending paused: the saved SMTP password can no longer be read: type it again in Settings > Email.");
                    break;
                default:
                    _logger.LogInformation("Email sending is on: {Settings}", settings);
                    break;
            }
        }

        if (state != "on")
        {
            return;
        }

        using var scope = _scopes.CreateScope();
        var outbox = scope.ServiceProvider.GetRequiredService<IEmailOutboxRepository>();
        var ids = await outbox.ClaimAsync(BatchSize, LeaseMinutes, stoppingToken);
        if (ids.Count == 0)
        {
            return;
        }

        int sent = 0, failed = 0;
        foreach (var id in ids)
        {
            var email = await outbox.GetAsync(id, stoppingToken);
            if (email is null)
            {
                continue;
            }

            try
            {
                var attachment = email.AttachmentContent is { Length: > 0 } content
                    ? new Model.DTOs.Messaging.EmailAttachment(email.AttachmentName ?? "attachment",
                        email.AttachmentContentType ?? "application/octet-stream", content)
                    : null;
                await _sender.SendAsync(new OutgoingEmail(email.ToAddresses, email.CcAddresses, email.Subject, email.BodyHtml, attachment),
                    settings, stoppingToken);
                await outbox.MarkSentAsync(id, stoppingToken);
                sent++;
            }
            catch (EmailSendException ex)
            {
                await outbox.MarkFailedAsync(id, ex.Message, MaxAttempts, stoppingToken);
                failed++;
                _logger.LogWarning("Email {EmailId} not sent (attempt {Attempt}): {Error}", id, email.Attempts, ex.Message);
            }
        }

        _logger.LogInformation("Email outbox: {Sent} sent, {Failed} failed of {Claimed} claimed.", sent, failed, ids.Count);
    }
}
