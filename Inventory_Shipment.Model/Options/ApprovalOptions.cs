namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "Approvals" configuration section.</summary>
public sealed class ApprovalOptions
{
    public const string SectionName = "Approvals";

    /// <summary>
    /// How often the reminder worker looks for purchase orders waiting longer than the reminder delay of
    /// Settings > Purchase approval. The delay itself (hours) is the page's; this is only how often it is checked.
    /// </summary>
    public int ReminderCheckMinutes { get; set; } = 15;
}
