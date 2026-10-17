using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

public interface ISqlConnectionFactory
{
    /// <summary>Returns a new, closed connection. Dapper opens it for the duration of each call.</summary>
    SqlConnection Create();

    /// <summary>
    /// The commandTimeout to give a call that works on many containers at once (<see cref="DatabaseOptions.BatchCommandTimeoutSeconds"/>),
    /// or null when the connection's own default is already as long (or waits forever): pass it as is to Dapper.
    /// </summary>
    int? BatchCommandTimeout { get; }
}
