using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Repository.Database;

public sealed class SqlConnectionFactory : ISqlConnectionFactory
{
    private readonly string _connectionString;

    public SqlConnectionFactory(IOptions<DatabaseOptions> options)
    {
        var connectionString = options.Value.ConnectionString;
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException(
                "Connection string 'DefaultConnection' is missing. Add it to appsettings.json under ConnectionStrings.");
        }

        _connectionString = WithCommandTimeout(connectionString, options.Value.CommandTimeoutSeconds);
        BatchCommandTimeout = LongerTimeout(_connectionString, options.Value.BatchCommandTimeoutSeconds);
    }

    public SqlConnection Create() => new(_connectionString);

    public int? BatchCommandTimeout { get; }

    /// <summary>
    /// <paramref name="seconds"/> when it is longer than what the connection string gives every command; null otherwise -
    /// a "Command Timeout=0" (wait forever) is never shortened, and Dapper keeps the connection's default for null.
    /// </summary>
    internal static int? LongerTimeout(string connectionString, int seconds)
    {
        var current = new SqlConnectionStringBuilder(connectionString).CommandTimeout;
        return seconds > 0 && current > 0 && seconds > current ? seconds : null;
    }

    /// <summary>
    /// The default timeout of every command made on these connections, IN ONE PLACE rather than on each call: the
    /// "Command Timeout" keyword is the default SqlClient gives a command, and Dapper keeps it for every call made
    /// without its own commandTimeout. A connection string that sets it keeps its value (the local "Command
    /// Timeout=0" waits forever); one that does not - the server's - gets <see cref="DatabaseOptions.CommandTimeoutSeconds"/>,
    /// which waits longer than the matching lock (see there).
    /// </summary>
    internal static string WithCommandTimeout(string connectionString, int seconds)
    {
        var builder = new SqlConnectionStringBuilder(connectionString);
        if (seconds <= 0 || builder.ShouldSerialize("Command Timeout"))
        {
            return connectionString;
        }

        builder.CommandTimeout = seconds;
        return builder.ConnectionString;
    }
}
