namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "Purchase" configuration section.</summary>
public sealed class PurchaseOptions
{
    public const string SectionName = "Purchase";

    /// <summary>
    /// The most a purchase line may be discounted, in percent.
    ///
    /// The same ceiling the sales side has, for the same reason: it catches the 150 that is a typo,
    /// not a decision, and it is open by default (100) so an installation that never chose a limit
    /// does not have supplier invoices refused by one. The procedure does the check and its message
    /// names the number.
    /// </summary>
    public decimal MaxDiscountPercent { get; set; } = 100m;
}
