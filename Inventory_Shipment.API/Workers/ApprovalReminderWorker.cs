using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.API.Workers;

/// <summary>
/// Reminds the approvers of purchase orders still waiting after the reminder delay of Settings > Purchase
/// approval: every Approvals:ReminderCheckMinutes minutes (default 15) usp_PurchaseOrder_DueReminders issues new
/// links (history "Reminder sent") and the reminder emails are queued.
///
/// QUIET WHEN THERE IS NOTHING TO DO: it logs only when orders were reminded. IT NEVER STOPS: an error is
/// logged and the next check runs. While the address of the application is not set it does not run, so the
/// reminders are not used up by emails whose links would point nowhere.
/// </summary>
public sealed class ApprovalReminderWorker : BackgroundService
{
    private const int MaxOrdersPerCheck = 50;

    private readonly IServiceScopeFactory _scopes;
    private readonly IEmailSettingsProvider _emailSettings;
    private readonly IOptionsMonitor<ApprovalOptions> _options;
    private readonly ILogger<ApprovalReminderWorker> _logger;

    public ApprovalReminderWorker(
        IServiceScopeFactory scopes, IEmailSettingsProvider emailSettings, IOptionsMonitor<ApprovalOptions> options,
        ILogger<ApprovalReminderWorker> logger)
    {
        _scopes = scopes;
        _emailSettings = emailSettings;
        _options = options;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var minutes = Math.Max(1, _options.CurrentValue.ReminderCheckMinutes);
        _logger.LogInformation("Approval reminders are checked every {Minutes} minute(s).", minutes);

        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(minutes));
        while (await WaitAsync(timer, stoppingToken))
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
                _logger.LogError(ex, "Approval reminders: the check failed; the next one runs in {Minutes} minute(s).", minutes);
            }
        }
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
        if ((await _emailSettings.GetAsync(stoppingToken)).PublicBaseUrl is null)
        {
            return;
        }

        using var scope = _scopes.CreateScope();
        var rows = await scope.ServiceProvider.GetRequiredService<IPurchaseApprovalRepository>().DueRemindersAsync(MaxOrdersPerCheck, stoppingToken);
        if (rows.Count == 0)
        {
            return;
        }

        await scope.ServiceProvider.GetRequiredService<IPurchaseApprovalMailer>()
            .RequestIssuedAsync(rows, ApprovalRequestKind.Reminder, null, stoppingToken);
        _logger.LogInformation("Approval reminders: {Orders} order(s) reminded, {Approvers} approver(s).",
            rows.Select(r => r.PurchaseDocumentId).Distinct().Count(), rows.Count);
    }
}
