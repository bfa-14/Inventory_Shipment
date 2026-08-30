using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Security;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IPermissionRepository
{
    /// <summary>Every permission, ordered by module then sort order.</summary>
    Task<IReadOnlyList<Permission>> GetAllAsync(CancellationToken cancellationToken = default);

    /// <summary>Which roles hold which permission, for the catalog view.</summary>
    Task<IReadOnlyList<(int PermissionId, string RoleName)>> GetRoleNamesByPermissionAsync(
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Pushes the application's catalog into security.Permissions (security.usp_Permission_SyncCatalog),
    /// which also re-grants every permission to every system role.
    /// </summary>
    Task SyncCatalogAsync(IEnumerable<PermissionDefinition> catalog, CancellationToken cancellationToken = default);
}
