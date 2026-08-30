using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Security;

namespace Inventory_Shipment.Service.Mapping;

public static class UserMapper
{
    /// <summary>
    /// Maps a user without its roles - for list views that fill Roles/RoleIds from a separate
    /// bulk query. Permissions stay empty.
    /// </summary>
    public static UserDto ToDto(this User user) => user.ToDto(UserAccess.Empty);

    public static UserDto ToDto(this User user, UserAccess access) => new()
    {
        Id = user.Id,
        Username = user.Username,
        Email = user.Email,
        FullName = user.FullName,
        Roles = access.Roles.Select(r => r.Name).ToArray(),
        RoleIds = access.Roles.Select(r => r.Id).ToArray(),
        Permissions = access.Permissions.ToArray(),
        IsActive = user.IsActive,
        LastLoginAtUtc = user.LastLoginAtUtc.AsUtc(),
        CreatedAtUtc = user.CreatedAtUtc.AsUtc()
    };

    /// <summary>Copy of a mapped user with the roles supplied separately (users list).</summary>
    public static UserDto WithRoles(this UserDto dto, IReadOnlyList<(int Id, string Name)> roles) => new()
    {
        Id = dto.Id,
        Username = dto.Username,
        Email = dto.Email,
        FullName = dto.FullName,
        Roles = roles.Select(r => r.Name).ToArray(),
        RoleIds = roles.Select(r => r.Id).ToArray(),
        Permissions = dto.Permissions,
        IsActive = dto.IsActive,
        LastLoginAtUtc = dto.LastLoginAtUtc,
        CreatedAtUtc = dto.CreatedAtUtc
    };
}
