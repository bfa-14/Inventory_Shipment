using Inventory_Shipment.Model.Security;
using Microsoft.AspNetCore.Authorization;

namespace Inventory_Shipment.API.Authorization;

/// <summary>
/// Succeeds when the access token carries the required permission code. Permissions are baked into
/// the token at sign-in, so this needs no database round-trip.
/// </summary>
public sealed class PermissionAuthorizationHandler : AuthorizationHandler<PermissionRequirement>
{
    protected override Task HandleRequirementAsync(AuthorizationHandlerContext context, PermissionRequirement requirement)
    {
        if (context.User.HasClaim(Permissions.ClaimType, requirement.Permission))
        {
            context.Succeed(requirement);
        }

        return Task.CompletedTask;
    }
}
