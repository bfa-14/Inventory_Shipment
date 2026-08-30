using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Roles;

public sealed class CreateRoleRequest
{
    [Required]
    [StringLength(50, MinimumLength = 2)]
    public string Name { get; init; } = string.Empty;

    [StringLength(250)]
    public string? Description { get; init; }

    /// <summary>Permissions to grant to the new role. May be empty.</summary>
    public int[] PermissionIds { get; init; } = [];
}

public sealed class UpdateRoleRequest
{
    [Required]
    [StringLength(50, MinimumLength = 2)]
    public string Name { get; init; } = string.Empty;

    [StringLength(250)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;
}

public sealed class SetRolePermissionsRequest
{
    /// <summary>The complete set of permissions the role should hold. An empty array revokes them all.</summary>
    [Required]
    public int[] PermissionIds { get; init; } = [];
}
