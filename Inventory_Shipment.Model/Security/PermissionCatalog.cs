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

    public static class MasterData
    {
        public const string BranchesView = "masterdata.branches.view";
        public const string BranchesCreate = "masterdata.branches.create";
        public const string BranchesEdit = "masterdata.branches.edit";
        public const string BranchesDelete = "masterdata.branches.delete";
        public const string WarehousesView = "masterdata.warehouses.view";
        public const string WarehousesCreate = "masterdata.warehouses.create";
        public const string WarehousesEdit = "masterdata.warehouses.edit";
        public const string WarehousesDelete = "masterdata.warehouses.delete";
    }

    private const string SecurityModule = "Security";
    private const string MasterDataModule = "Master Data";

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

        new(MasterData.BranchesView, "View branches", MasterDataModule,
            "See the Branches / Sites list.", 100),
        new(MasterData.BranchesCreate, "Create branches", MasterDataModule,
            "Add new branches / sites.", 110),
        new(MasterData.BranchesEdit, "Edit branches", MasterDataModule,
            "Change branch details and activate / deactivate them.", 120),
        new(MasterData.BranchesDelete, "Delete branches", MasterDataModule,
            "Delete branches that are not referenced by other records.", 130),

        new(MasterData.WarehousesView, "View warehouses", MasterDataModule,
            "See the Warehouses list.", 140),
        new(MasterData.WarehousesCreate, "Create warehouses", MasterDataModule,
            "Add new warehouses.", 150),
        new(MasterData.WarehousesEdit, "Edit warehouses", MasterDataModule,
            "Change warehouse details and activate / deactivate them.", 160),
        new(MasterData.WarehousesDelete, "Delete warehouses", MasterDataModule,
            "Delete warehouses that hold no inventory and are not referenced by other records.", 170),
    ];
}
