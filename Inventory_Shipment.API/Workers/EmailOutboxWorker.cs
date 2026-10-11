using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Implementations;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.API.Workers;

/// <summary>
/// Sends the queued emails: every 30 seconds, while sending is on, it claims up to 10 due emails and sends
/// them one by one; each is marked Sent, or Failed with the sender's readable error (retried later, given up
/// after 5 attempts).
///
/// SENDING OFF = NOTHING LEAVES THE SERVER: the emails stay Pending, readable in the Email log, and are sent
/// once sending is switched on. The worker says so when the state changes, not every cycle.
///
/// THE TESTING ENVIRONMENT NEVER EMAILS REAL PEOPLE (App:Environment = "testing"): its database is usually a
/// copy of production, full of real suppliers' and approvers' addresses. Without App:TestEmailRedirectTo, or
/// with one that is not a valid address, it behaves as if sending were off: nothing is claimed, the emails
/// stay Pending and readable in the Email log. With one, every email goes to that address alone, marked
/// "[TEST]" and with a note naming the recipients it was written for (see <see cref="TestEnvironmentEmail"/>),
/// then is marked Sent or Failed as usual. The switch and the password of Settings > Email still come first.
/// Production sends exactly as before.
///
/// TESTING NEVER SENDS ON AN EMAIL WRITTEN BY PRODUCTION: the copied outbox holds production's unsent emails
/// (and a tester can Retry its failed ones), finished HTML whose approval links open production with tokens
/// valid there. An email linking anywhere but this environment's address is closed (Failed at once, the reason
/// in the Email log) instead of redirected, whatever the copy script did to it. An unexpected App:Environment
/// counts as testing and is named in a warning: on production the cure is to correct it, not to redirect.
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
    private readonly IOptionsMonitor<AppOptions> _app;
    private readonly ILogger<EmailOutboxWorker> _logger;
    private string? _lastState;

    public EmailOutboxWorker(
        IServiceScopeFactory scopes, IEmailSettingsProvider settings, IEmailSender sender, IOptionsMonitor<AppOptions> app,
        ILogger<EmailOutboxWorker> logger)
    {
        _scopes = scopes;
        _settings = settings;
        _sender = sender;
        _app = app;
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
        var app = _app.CurrentValue;
        var environment = app.Environment?.Trim();
        var testAddress = app.TestEmailRedirectTo?.Trim();
        var state = !settings.SendingEnabled ? "off"
            : settings.PasswordUnreadable ? "unreadable"
            : !app.IsTesting ? "on"
            : string.IsNullOrEmpty(testAddress) ? "test-held"
            : !TestEnvironmentEmail.IsValidRedirect(testAddress) ? "test-invalid"
            : "test-redirect";

        // In testing, the environment and the test address are part of the state, so that changing either is
        // reported like switching sending on or off. Production keeps the plain state.
        var reported = app.IsTesting ? $"{state} {environment} {testAddress}" : state;
        if (reported != _lastState)
        {
            _lastState = reported;
            if (app.IsUnexpectedEnvironment)
            {
                _logger.LogWarning(
                    "App:Environment is \"{Environment}\", neither \"production\" nor \"testing\": it counts as testing, so no email reaches "
                    + "its real recipients. On the production server, correct ENVIRONMENT in deploy/.env; TEST_EMAIL_REDIRECT_TO would "
                    + "send every email to that one address instead.",
                    environment);
            }

            switch (state)
            {
                case "off":
                    _logger.LogInformation("Email sending is off: nothing to send, queued emails stay Pending in the Email log.");
                    break;
                case "unreadable":
                    _logger.LogWarning("Email sending paused: the saved SMTP password can no longer be read: type it again in Settings > Email.");
                    break;
                case "test-held":
                    _logger.LogInformation(
                        "Testing environment (App:Environment \"{Environment}\"): emails stay Pending in the Email log and are never sent "
                        + "to real recipients. Set TEST_EMAIL_REDIRECT_TO in deploy/.env to receive them at one test address.",
                        environment);
                    break;
                case "test-invalid":
                    _logger.LogWarning(
                        "Testing environment (App:Environment \"{Environment}\"): the test address \"{Address}\" (App:TestEmailRedirectTo) "
                        + "is not one valid email address, so emails stay Pending in the Email log and are never sent. "
                        + "Correct TEST_EMAIL_REDIRECT_TO in deploy/.env.",
                        environment, testAddress);
                    break;
                case "test-redirect":
                    _logger.LogInformation(
                        "Testing environment (App:Environment \"{Environment}\"): email sending is on, every email goes to {Address} only, "
                        + "marked [TEST]: {Settings}",
                        environment, testAddress, settings);
                    break;
                default:
                    _logger.LogInformation("Email sending is on: {Settings}", settings);
                    break;
            }
        }

        if (state is not ("on" or "test-redirect"))
        {
            return;
        }

        // Null in production: the email goes to the recipients it was queued for.
        var redirectTo = state == "test-redirect" ? testAddress : null;

        using var scope = _scopes.CreateScope();
        var outbox = scope.ServiceProvider.GetRequiredService<IEmailOutboxRepository>();
        var ids = await outbox.ClaimAsync(BatchSize, LeaseMinutes, stoppingToken);
        if (ids.Count == 0)
        {
            return;
        }

        int sent = 0, failed = 0, closed = 0;
        foreach (var id in ids)
        {
            var email = await outbox.GetAsync(id, stoppingToken);
            if (email is null)
            {
                continue;
            }

            // Testing only: an email whose links open another environment is closed, never sent (class comment).
            // maxAttempts 1: the claim has counted this attempt, so it is Failed for good; a Retry ends here again.
            if (redirectTo is not null
                && TestEnvironmentEmail.ForeignLinkOrigin(email.BodyHtml, settings.PublicBaseUrl) is { } foreign)
            {
                await outbox.MarkFailedAsync(id,
                    $"Not sent from the testing environment: its links open {foreign}, not this environment "
                    + $"({settings.PublicBaseUrl ?? "no address in Settings > Email"}). It was most likely copied from production, "
                    + "where its links would act.",
                    1, stoppingToken);
                closed++;
                _logger.LogWarning("Email {EmailId} not sent from testing: its links open {Origin}, another environment.", id, foreign);
                continue;
            }

            try
            {
                var attachment = email.AttachmentContent is { Length: > 0 } content
                    ? new Model.DTOs.Messaging.EmailAttachment(email.AttachmentName ?? "attachment",
                        email.AttachmentContentType ?? "application/octet-stream", content)
                    : null;
                var outgoing = new OutgoingEmail(email.ToAddresses, email.CcAddresses, email.Subject, email.BodyHtml, attachment);
                if (redirectTo is not null)
                {
                    outgoing = TestEnvironmentEmail.Redirect(outgoing, redirectTo);
                }

                await _sender.SendAsync(outgoing, settings, stoppingToken);
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

        if (redirectTo is null)
        {
            _logger.LogInformation("Email outbox: {Sent} sent, {Failed} failed of {Claimed} claimed.", sent, failed, ids.Count);
        }
        else
        {
            _logger.LogInformation(
                "Email outbox (testing): {Sent} sent to {Address}, {Failed} failed, {Closed} closed (links to another environment) of {Claimed} claimed.",
                sent, redirectTo, failed, closed, ids.Count);
        }
    }
}
