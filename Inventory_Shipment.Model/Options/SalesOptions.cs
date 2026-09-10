namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "Sales" configuration section.</summary>
public sealed class SalesOptions
{
    public const string SectionName = "Sales";

    /// <summary>
    /// The most a line may be discounted, in percent.
    ///
    /// A CEILING RATHER THAN A RULE ABOUT WHO MAY DISCOUNT. It exists to catch the file with 150 in
    /// the Discount column, which is a typo rather than a decision, and it is deliberately open by
    /// default (100 = anything up to free) so that an installation which has not thought about it
    /// does not have imports refused by a limit nobody chose.
    ///
    /// The check itself is the procedure's: this value is passed to usp_InvoiceImport_Validate and
    /// the message a person reads names the number.
    /// </summary>
    public decimal MaxDiscountPercent { get; set; } = 100m;
}
