using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Runs a database call again when SQL Server chose it as a deadlock victim.
///
/// A POSTING AND A READ OF THE SAME CHAIN CAN DEADLOCK: posting a purchase invoice updates the order's
/// lines and then its header, while a reader of that order holds the header and asks for the lines.
/// SQL Server kills one of the two (error 1205) and rolls it back; the procedures are whole
/// transactions, so running the killed one again is exactly what the message asks for — and far
/// better than a 500 for the person who pressed Post a moment before somebody opened the order.
/// </summary>
public static class SqlRetry
{
    private const int DeadlockVictim = 1205;
    private const int Attempts = 3;

    public static async Task<T> OnDeadlockAsync<T>(Func<Task<T>> call, CancellationToken cancellationToken = default)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await call();
            }
            catch (SqlException ex) when (ex.Number == DeadlockVictim && attempt < Attempts)
            {
                // A short, growing pause so the two do not collide again at once.
                await Task.Delay(TimeSpan.FromMilliseconds(100 * attempt), cancellationToken);
            }
        }
    }

    public static Task OnDeadlockAsync(Func<Task> call, CancellationToken cancellationToken = default)
        => OnDeadlockAsync(async () =>
        {
            await call();
            return true;
        }, cancellationToken);
}
