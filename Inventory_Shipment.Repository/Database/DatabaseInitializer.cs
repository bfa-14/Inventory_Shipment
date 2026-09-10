using System.Diagnostics;
using System.Reflection;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Creates the database (optional) and runs the embedded, idempotent Schema.sql.
/// </summary>
public sealed partial class DatabaseInitializer : IDatabaseInitializer
{
    private const string SchemaResourceName = "Inventory_Shipment.Repository.Database.Schema.sql";

    /// <summary>
    /// A batch slower than this is logged with its own line.
    ///
    /// Almost every batch is a CREATE OR ALTER that takes single-digit milliseconds, so a threshold
    /// this low is quiet in normal operation and loud exactly when something is worth reading: the
    /// batch that waited on a lock, or the one that rebuilt an index. Logging all three hundred would
    /// bury that line in noise, and logging none is what left "Execution Timeout Expired" with
    /// nothing to attach it to.
    /// </summary>
    private static readonly TimeSpan SlowBatch = TimeSpan.FromSeconds(2);

    /// <summary>Enough of a batch to recognise it in a log line without pasting a procedure into the log.</summary>
    private const int BatchPreviewLength = 200;

    /// <summary>
    /// Sessions other than this one holding a lock that a schema change would have to wait behind.
    ///
    /// X and Sch-M ONLY, because those are the two that actually block a CREATE OR ALTER: an
    /// exclusive data lock, and a schema-modification lock. Shared and intent locks are what a
    /// healthy busy database looks like and warning about them would cry wolf on every start-up.
    /// </summary>
    private const string BlockingLocksSql = """
        SELECT COUNT(*) FROM sys.dm_tran_locks
        WHERE resource_database_id = DB_ID()
          AND request_session_id <> @@SPID
          AND request_mode IN ('X', 'Sch-M')
        """;

    private readonly DatabaseOptions _options;
    private readonly ILogger<DatabaseInitializer> _logger;

    public DatabaseInitializer(IOptions<DatabaseOptions> options, ILogger<DatabaseInitializer> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        var builder = new SqlConnectionStringBuilder(_options.ConnectionString);
        var databaseName = builder.InitialCatalog;

        if (string.IsNullOrWhiteSpace(databaseName))
        {
            throw new InvalidOperationException(
                "The connection string must specify a database (Database=... / Initial Catalog=...).");
        }

        try
        {
            if (_options.CreateDatabaseIfMissing)
            {
                await EnsureDatabaseExistsAsync(builder, databaseName, cancellationToken);
            }

            if (_options.ApplySchemaOnStartup)
            {
                await ApplySchemaAsync(cancellationToken);
            }
        }
        catch (SqlException ex)
        {
            throw new InvalidOperationException(
                $"Could not initialize database '{databaseName}' on server '{builder.DataSource}'. " +
                "Check ConnectionStrings:DefaultConnection in appsettings.json and that SQL Server is running. " +
                $"SQL error {ex.Number}: {ex.Message}", ex);
        }
    }

    private async Task EnsureDatabaseExistsAsync(
        SqlConnectionStringBuilder builder, string databaseName, CancellationToken cancellationToken)
    {
        var masterBuilder = new SqlConnectionStringBuilder(builder.ConnectionString) { InitialCatalog = "master" };

        await using var connection = new SqlConnection(masterBuilder.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        var exists = await connection.ExecuteScalarAsync<int?>(
            new CommandDefinition("SELECT DB_ID(@Name)", new { Name = databaseName }, cancellationToken: cancellationToken));

        if (exists.HasValue)
        {
            return;
        }

        _logger.LogInformation("Database {Database} not found - creating it.", databaseName);

        // Database names cannot be parameterized; QUOTENAME guards against injection.
        var sql = await connection.ExecuteScalarAsync<string>(
            new CommandDefinition("SELECT N'CREATE DATABASE ' + QUOTENAME(@Name)", new { Name = databaseName },
                cancellationToken: cancellationToken));

        await connection.ExecuteAsync(new CommandDefinition(sql!, cancellationToken: cancellationToken));
    }

    /// <summary>
    /// Runs every batch of the embedded schema, in order, saying which one is slow and which one
    /// failed.
    ///
    /// THE WHOLE POINT OF THE INSTRUMENTATION IS THE FAILURE MESSAGE. "Execution Timeout Expired" on
    /// its own is unactionable: three hundred batches ran, one of them stopped, and nothing says
    /// which. A blocked schema apply is almost always somebody's uncommitted transaction in SSMS, so
    /// the index, the elapsed time and the first line of the batch text are exactly what turns a
    /// mystery into "batch 214, the CREATE on StockDocuments, waiting behind session 63".
    /// </summary>
    private async Task ApplySchemaAsync(CancellationToken cancellationToken)
    {
        var script = await ReadSchemaScriptAsync(cancellationToken);
        var batches = GoSeparator().Split(script)
            .Select(b => b.Trim())
            .Where(b => b.Length > 0)
            .ToList();

        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        await WarnOnBlockingLocksAsync(connection, cancellationToken);

        var timeout = _options.SchemaCommandTimeoutSeconds;
        var total = Stopwatch.StartNew();

        for (var index = 0; index < batches.Count; index++)
        {
            var batch = batches[index];
            var watch = Stopwatch.StartNew();

            try
            {
                await connection.ExecuteAsync(new CommandDefinition(
                    batch, commandTimeout: timeout, cancellationToken: cancellationToken));
            }
            catch (Exception ex)
            {
                // BEFORE THE RETHROW, so the culprit is in the log even though the exception that
                // reaches the host is the original one with its own (useless) message.
                _logger.LogError(ex,
                    "Schema batch {Batch}/{Total} failed after {Elapsed} ms: {Preview}",
                    index + 1, batches.Count, watch.ElapsedMilliseconds, Preview(batch));
                throw;
            }

            watch.Stop();
            if (watch.Elapsed >= SlowBatch)
            {
                _logger.LogInformation(
                    "Schema batch {Batch}/{Total} took {Elapsed} ms: {Preview}",
                    index + 1, batches.Count, watch.ElapsedMilliseconds, Preview(batch));
            }
        }

        _logger.LogInformation("Database schema verified ({BatchCount} batches in {Elapsed} ms).",
            batches.Count, total.ElapsedMilliseconds);
    }

    /// <summary>
    /// Says so when something else is already holding the database open.
    ///
    /// A WARNING, NOT A REFUSAL. The apply may well succeed — the blocker may be nowhere near the
    /// tables this touches — so refusing to start over it would be worse than the problem. What it
    /// buys is the reading order: this line comes out BEFORE the batch that stalls, so a slow start
    /// is explained while it is happening rather than after it has failed.
    ///
    /// THE PROBE ITSELF NEVER FAILS THE START-UP. It is a diagnostic; a diagnostic that can take the
    /// application down is a liability, and being unable to read a DMV (a login without VIEW SERVER
    /// STATE, most likely) says nothing about whether the schema can be applied.
    /// </summary>
    private async Task WarnOnBlockingLocksAsync(SqlConnection connection, CancellationToken cancellationToken)
    {
        try
        {
            var held = await connection.ExecuteScalarAsync<int>(new CommandDefinition(
                BlockingLocksSql, commandTimeout: 10, cancellationToken: cancellationToken));

            if (held > 0)
            {
                _logger.LogWarning(
                    "Other sessions hold exclusive locks in the database - the schema apply may block. "
                    + "({LockCount} X / Sch-M lock(s) held by other sessions.)", held);
            }
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Could not read sys.dm_tran_locks; continuing without the lock check.");
        }
    }

    /// <summary>The first line or two of a batch, flattened, so a log line stays one line.</summary>
    private static string Preview(string batch)
    {
        var flat = batch.Length <= BatchPreviewLength ? batch : batch[..BatchPreviewLength] + "...";
        return flat.ReplaceLineEndings(" ");
    }

    private static async Task<string> ReadSchemaScriptAsync(CancellationToken cancellationToken)
    {
        var assembly = Assembly.GetExecutingAssembly();
        await using var stream = assembly.GetManifestResourceStream(SchemaResourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{SchemaResourceName}' was not found.");
        using var reader = new StreamReader(stream);
        return await reader.ReadToEndAsync(cancellationToken);
    }

    // Splits on lines that contain only "GO" (case-insensitive), as SSMS does.
    [GeneratedRegex(@"^\s*GO\s*(--.*)?$", RegexOptions.Multiline | RegexOptions.IgnoreCase)]
    private static partial Regex GoSeparator();
}
