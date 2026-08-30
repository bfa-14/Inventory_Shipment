namespace Inventory_Shipment.Model.Security;

/// <summary>One entry of the permission catalog owned by the application code.</summary>
public sealed record PermissionDefinition(string Code, string Name, string Module, string Description, int SortOrder);

/// <summary>
/// The permissions this application knows about. The catalog is the source of truth: it is pushed into
/// security.Permissions on every start-up (see ISecurityBootstrapper), which also grants every system role
/// every permission. Guard endpoints with [HasPermission(Permissions.Security.UsersView)] and menu items
/// with the same codes.
/// </summary>
public static class Permissions
{
    /// <summary>JWT claim type carrying one permission code per claim.</summary>
    public const string ClaimType = "permission";

    public static class Security
    {
        public const string UsersView = "security.users.view";
        public const string UsersCreate = "security.users.create";
        public const string UsersEdit = "security.users.edit";
        public const string RolesView = "security.roles.view";
        public const string RolesManage = "security.roles.manage";
        public const string PermissionsView = "security.permissions.view";
        public const string AuditView = "security.audit.view";
    }

    private const string SecurityModule = "Security";

    public static IReadOnlyList<PermissionDefinition> All { get; } =
    [
        new(Security.UsersView, "View users", SecurityModule,
            "See the list of user accounts and their details.", 10),
        new(Security.UsersCreate, "Create users", SecurityModule,
            "Add new user accounts.", 20),
        new(Security.UsersEdit, "Edit users", SecurityModule,
            "Change a user's profile, roles, status and password.", 30),
        new(Security.RolesView, "View roles", SecurityModule,
            "See the list of roles and the permissions they hold.", 40),
        new(Security.RolesManage, "Manage roles", SecurityModule,
            "Create, edit and delete roles and change their permissions.", 50),
        new(Security.PermissionsView, "View permissions", SecurityModule,
            "Browse the catalog of permissions defined by the application.", 60),
        new(Security.AuditView, "View login audit", SecurityModule,
            "Read the record of successful and failed sign-in attempts.", 70),
    ];
}
