using Microsoft.AspNetCore.Authorization;

namespace Inventory_Shipment.API.Authorization;

/// <summary>
/// Requires a permission code on an action or controller, e.g.
/// <c>[HasPermission(Permissions.Security.UsersView)]</c>. The policy is materialised on demand by
/// <see cref="PermissionPolicyProvider"/>.
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = true, Inherited = true)]
public sealed class HasPermissionAttribute : AuthorizeAttribute
{
    public HasPermissionAttribute(string permission)
    {
        Permission = permission;
        Policy = PermissionPolicyProvider.Prefix + permission;
    }

    public string Permission { get; }
}
