using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>A role together with the counts shown in the roles list.</summary>
public sealed record RoleWithCounts(Role Role, int UserCount, int PermissionCount);

public interface IRoleRepository
{
    Task<IReadOnlyList<RoleWithCounts>> GetAllAsync(CancellationToken cancellationToken = default);

    Task<RoleWithCounts?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    Task<Role?> GetByNameAsync(string name, CancellationToken cancellationToken = default);

    Task<bool> NameExistsAsync(string name, int? excludeRoleId = null, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<int>> GetPermissionIdsAsync(int roleId, CancellationToken cancellationToken = default);

    /// <summary>Inserts the role and returns the generated Id (also set on <paramref name="role"/>).</summary>
    Task<int> CreateAsync(Role role, CancellationToken cancellationToken = default);

    Task<bool> UpdateAsync(Role role, CancellationToken cancellationToken = default);

    /// <summary>security.usp_Role_Delete - throws <c>SecurityRuleException</c> 50001 / 50005 / 50006.</summary>
    Task DeleteAsync(int roleId, CancellationToken cancellationToken = default);

    /// <summary>security.usp_Role_SetPermissions - throws <c>SecurityRuleException</c> 50001 / 50002.</summary>
    Task SetPermissionsAsync(int roleId, IEnumerable<int> permissionIds, CancellationToken cancellationToken = default);
}
