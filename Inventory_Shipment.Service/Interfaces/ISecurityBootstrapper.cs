namespace Inventory_Shipment.Service.Interfaces;

public interface ISecurityBootstrapper
{
    /// <summary>
    /// Pushes the application's permission catalog into the database. Runs on every start-up, before
    /// seeding, so new permission codes exist before any role or user references them.
    /// </summary>
    Task SyncPermissionCatalogAsync(CancellationToken cancellationToken = default);
}
