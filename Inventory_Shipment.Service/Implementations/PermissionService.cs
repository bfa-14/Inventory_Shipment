using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Roles;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

public sealed class PermissionService : IPermissionService
{
    private readonly IPermissionRepository _permissions;

    public PermissionService(IPermissionRepository permissions)
    {
        _permissions = permissions;
    }

    public async Task<Result<IReadOnlyList<PermissionModuleDto>>> GetCatalogAsync(CancellationToken cancellationToken = default)
    {
        var permissions = await _permissions.GetAllAsync(cancellationToken);
        var rolesByPermission = await _permissions.GetRoleNamesByPermissionAsync(cancellationToken);

        var roleLookup = rolesByPermission
            .GroupBy(r => r.PermissionId)
            .ToDictionary(g => g.Key, g => g.Select(r => r.RoleName).ToArray());

        var modules = permissions
            .GroupBy(p => p.Module)
            .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase)
            .Select(g => new PermissionModuleDto
            {
                Module = g.Key,
                Permissions = g
                    .OrderBy(p => p.SortOrder)
                    .ThenBy(p => p.Code, StringComparer.OrdinalIgnoreCase)
                    .Select(p => new PermissionDto
                    {
                        Id = p.Id,
                        Code = p.Code,
                        Name = p.Name,
                        Module = p.Module,
                        Description = p.Description,
                        SortOrder = p.SortOrder,
                        Roles = roleLookup.TryGetValue(p.Id, out var names) ? names : []
                    })
                    .ToArray()
            })
            .ToList();

        return Result<IReadOnlyList<PermissionModuleDto>>.Success(modules);
    }
}
