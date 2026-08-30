namespace Inventory_Shipment.Service.Interfaces;

public interface IDataSeeder
{
    /// <summary>Creates the initial administrator when the Users table is empty.</summary>
    Task SeedAsync(CancellationToken cancellationToken = default);
}
