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

    private async Task ApplySchemaAsync(CancellationToken cancellationToken)
    {
        var script = await ReadSchemaScriptAsync(cancellationToken);
        var batches = GoSeparator().Split(script)
            .Select(b => b.Trim())
            .Where(b => b.Length > 0)
            .ToList();

        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        foreach (var batch in batches)
        {
            await connection.ExecuteAsync(new CommandDefinition(batch, cancellationToken: cancellationToken));
        }

        _logger.LogInformation("Database schema verified ({BatchCount} batches).", batches.Count);
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
