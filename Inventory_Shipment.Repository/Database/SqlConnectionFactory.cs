using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Repository.Database;

public sealed class SqlConnectionFactory : ISqlConnectionFactory
{
    private readonly string _connectionString;

    public SqlConnectionFactory(IOptions<DatabaseOptions> options)
    {
        _connectionString = options.Value.ConnectionString;
        if (string.IsNullOrWhiteSpace(_connectionString))
        {
            throw new InvalidOperationException(
                "Connection string 'DefaultConnection' is missing. Add it to appsettings.json under ConnectionStrings.");
        }
    }

    public SqlConnection Create() => new(_connectionString);
}
