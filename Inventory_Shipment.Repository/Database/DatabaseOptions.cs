namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Configured by the API from ConnectionStrings:DefaultConnection and the "Database" section.
/// </summary>
public sealed class DatabaseOptions
{
    public const string SectionName = "Database";

    public string ConnectionString { get; set; } = string.Empty;

    /// <summary>Create the database on the server if it does not exist yet (needs CREATE DATABASE permission).</summary>
    public bool CreateDatabaseIfMissing { get; set; } = true;

    /// <summary>Run the embedded Schema.sql on start-up (idempotent).</summary>
    public bool ApplySchemaOnStartup { get; set; } = true;
}
