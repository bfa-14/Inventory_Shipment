namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "App" configuration section: facts about where the application runs.</summary>
public sealed class AppOptions
{
    public const string SectionName = "App";

    /// <summary>
    /// The address of the web application (https://erp.example.com), used in the links put in emails.
    ///
    /// A FALLBACK ONLY: the address saved in Settings > Email wins. It lives in configuration too so
    /// that an installation can ship with the right address before anybody opens the page; empty here
    /// and on the page means no link can be built, and the procedures that would email one refuse.
    /// </summary>
    public string PublicBaseUrl { get; set; } = string.Empty;
}
