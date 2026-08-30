namespace Inventory_Shipment.Model.Security;

/// <summary>A role a user holds, as returned by security.usp_User_GetAccess.</summary>
public sealed record RoleRef(int Id, string Name);

/// <summary>
/// Everything the authorization layer needs about a user: the roles they hold and the flattened set of
/// permission codes those roles grant.
/// </summary>
public sealed class UserAccess
{
    public UserAccess(IReadOnlyList<RoleRef> roles, IReadOnlyList<string> permissions)
    {
        Roles = roles;
        Permissions = permissions;
    }

    public IReadOnlyList<RoleRef> Roles { get; }

    public IReadOnlyList<string> Permissions { get; }

    /// <summary>No roles and no permissions - used for list views that fill roles separately.</summary>
    public static UserAccess Empty { get; } = new([], []);
}
