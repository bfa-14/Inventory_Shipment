using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

public interface ISqlConnectionFactory
{
    /// <summary>Returns a new, closed connection. Dapper opens it for the duration of each call.</summary>
    SqlConnection Create();
}
