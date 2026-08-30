namespace Inventory_Shipment.Repository.Database;

public interface IDatabaseInitializer
{
    /// <summary>Creates the database if needed and applies the embedded schema script.</summary>
    Task InitializeAsync(CancellationToken cancellationToken = default);
}
