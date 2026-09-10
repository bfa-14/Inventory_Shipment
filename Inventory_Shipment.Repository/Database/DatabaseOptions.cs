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

    /// <summary>
    /// How long one schema batch may take before it is abandoned, in seconds.
    ///
    /// FIVE MINUTES RATHER THAN ADO.NET'S THIRTY SECONDS, because the two are answering different
    /// questions. Thirty seconds is right for a query serving a web request: past that, the user has
    /// gone. A schema batch has no user waiting, runs once at start-up, and can legitimately be slow
    /// — an index over a large table, or a CREATE that has to wait behind somebody's open transaction
    /// in SSMS. Timing that out at thirty seconds turns a slow start into a failed one, and the
    /// message it fails with ("Execution Timeout Expired") names neither the batch nor the blocker.
    ///
    /// It is still a ceiling and not a licence to hang: a batch blocked for five minutes is a real
    /// problem, and the error log names which batch it was.
    /// </summary>
    public int SchemaCommandTimeoutSeconds { get; set; } = 300;
}
