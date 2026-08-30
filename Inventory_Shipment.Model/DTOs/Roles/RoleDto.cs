namespace Inventory_Shipment.Model.DTOs.Roles;

/// <summary>A role as shown in the roles list.</summary>
public class RoleDto
{
    public int Id { get; init; }
    public string Name { get; init; } = string.Empty;
    public string? Description { get; init; }

    /// <summary>System roles always hold every permission and cannot be renamed, deactivated or deleted.</summary>
    public bool IsSystem { get; init; }

    public bool IsActive { get; init; }
    public int UserCount { get; init; }
    public int PermissionCount { get; init; }
    public DateTime CreatedAtUtc { get; init; }
}

/// <summary>A role plus the permissions it holds.</summary>
public sealed class RoleDetailDto : RoleDto
{
    public int[] PermissionIds { get; init; } = [];
    public PermissionDto[] Permissions { get; init; } = [];
}
