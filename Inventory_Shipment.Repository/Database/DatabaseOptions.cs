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

    /// <summary>
    /// How long one ordinary database call may take, in seconds, when the connection string does not say
    /// ("Command Timeout=..." in it always wins, 0 included).
    ///
    /// NINETY RATHER THAN ADO.NET'S THIRTY, BECAUSE OF THE MATCHING LOCK. Posting or cancelling a goods receipt, a
    /// supplier invoice or return, or a landed cost adjustment takes purchase.GoodsReceiptMatching
    /// (purchase.usp_GoodsReceipt_LockMatching), and waits up to SIXTY seconds for it before refusing with 63010 "Goods
    /// receipts and invoices are being matched for another user. Try again in a moment." With thirty seconds the
    /// client gave up first: "Execution Timeout Expired", a 500, and the sentence never shown. So this must stay ABOVE
    /// the lock's wait: lowering it below sixty brings the 500 back. 0 or less leaves SqlClient's own thirty seconds.
    /// </summary>
    public int CommandTimeoutSeconds { get; set; } = 90;
}
