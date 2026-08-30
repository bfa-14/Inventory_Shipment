namespace Inventory_Shipment.Model.DTOs.Roles;

/// <summary>A permission from the application catalog, with the roles that currently hold it.</summary>
public sealed class PermissionDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string Module { get; init; } = string.Empty;
    public string? Description { get; init; }
    public int SortOrder { get; init; }

    /// <summary>Names of the roles that hold this permission.</summary>
    public string[] Roles { get; init; } = [];
}

/// <summary>Permissions grouped by the module that owns them.</summary>
public sealed class PermissionModuleDto
{
    public string Module { get; init; } = string.Empty;
    public PermissionDto[] Permissions { get; init; } = [];
}
