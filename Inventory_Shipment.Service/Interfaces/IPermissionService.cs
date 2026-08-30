using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Roles;

namespace Inventory_Shipment.Service.Interfaces;

public interface IPermissionService
{
    /// <summary>The permission catalog grouped by module, each permission listing the roles that hold it.</summary>
    Task<Result<IReadOnlyList<PermissionModuleDto>>> GetCatalogAsync(CancellationToken cancellationToken = default);
}
