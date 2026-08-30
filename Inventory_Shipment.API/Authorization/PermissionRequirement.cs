using Microsoft.AspNetCore.Authorization;

namespace Inventory_Shipment.API.Authorization;

/// <summary>Requires the caller's token to carry one specific permission code.</summary>
public sealed class PermissionRequirement : IAuthorizationRequirement
{
    public PermissionRequirement(string permission)
    {
        Permission = permission;
    }

    public string Permission { get; }
}
