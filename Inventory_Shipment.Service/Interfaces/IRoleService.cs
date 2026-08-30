using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Roles;

namespace Inventory_Shipment.Service.Interfaces;

public interface IRoleService
{
    Task<Result<IReadOnlyList<RoleDto>>> GetAllAsync(CancellationToken cancellationToken = default);

    Task<Result<RoleDetailDto>> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<RoleDetailDto>> CreateAsync(CreateRoleRequest request, CancellationToken cancellationToken = default);

    Task<Result> UpdateAsync(int id, UpdateRoleRequest request, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    Task<Result> SetPermissionsAsync(int id, IEnumerable<int> permissionIds, CancellationToken cancellationToken = default);
}
