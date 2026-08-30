namespace Inventory_Shipment.Model.Options;

/// <summary>
/// Bound from the "Seed" configuration section. Used only when the Users table is empty,
/// to create the first administrator so you can log in.
/// </summary>
public sealed class SeedOptions
{
    public const string SectionName = "Seed";

    /// <summary>Set to false in environments where the first user is created by hand (e.g. with the SQL scripts).</summary>
    public bool Enabled { get; set; } = true;

    public string AdminUsername { get; set; } = "admin";
    public string AdminEmail { get; set; } = "admin@inventory.local";
    public string AdminFullName { get; set; } = "System Administrator";

    /// <summary>Leave empty in appsettings.json; supply it per environment (user-secrets / Seed__AdminPassword).</summary>
    public string AdminPassword { get; set; } = string.Empty;
}
