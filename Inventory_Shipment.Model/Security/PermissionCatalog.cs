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
        public const string CurrenciesView = "masterdata.currencies.view";
        public const string CurrenciesCreate = "masterdata.currencies.create";
        public const string CurrenciesEdit = "masterdata.currencies.edit";
        public const string CurrenciesDelete = "masterdata.currencies.delete";
        public const string ExchangeRatesView = "masterdata.exchangerates.view";
        public const string ExchangeRatesCreate = "masterdata.exchangerates.create";
        public const string ExchangeRatesEdit = "masterdata.exchangerates.edit";
        public const string ExchangeRatesDelete = "masterdata.exchangerates.delete";
        public const string ItemFamiliesView = "masterdata.itemfamilies.view";
        public const string ItemFamiliesCreate = "masterdata.itemfamilies.create";
        public const string ItemFamiliesEdit = "masterdata.itemfamilies.edit";
        public const string ItemFamiliesDelete = "masterdata.itemfamilies.delete";
        public const string BrandsView = "masterdata.brands.view";
        public const string BrandsCreate = "masterdata.brands.create";
        public const string BrandsEdit = "masterdata.brands.edit";
        public const string BrandsDelete = "masterdata.brands.delete";
        public const string UnitTypesView = "masterdata.unittypes.view";
        public const string UnitTypesCreate = "masterdata.unittypes.create";
        public const string UnitTypesEdit = "masterdata.unittypes.edit";
        public const string UnitTypesDelete = "masterdata.unittypes.delete";
    }

    public static class Inventory
    {
        public const string ItemsView = "inventory.items.view";
        public const string ItemsCreate = "inventory.items.create";
        public const string ItemsEdit = "inventory.items.edit";
        public const string ItemsDelete = "inventory.items.delete";
    }

    private const string SecurityModule = "Security";
    private const string MasterDataModule = "Master Data";
    private const string InventoryModule = "Inventory";

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

        new(MasterData.CurrenciesView, "View currencies", MasterDataModule,
            "See the Currencies list.", 180),
        new(MasterData.CurrenciesCreate, "Create currencies", MasterDataModule,
            "Add new currencies.", 190),
        new(MasterData.CurrenciesEdit, "Edit currencies", MasterDataModule,
            "Change currency details, the base currency and active status.", 200),
        new(MasterData.CurrenciesDelete, "Delete currencies", MasterDataModule,
            "Delete currencies that are not referenced by other records.", 210),

        new(MasterData.ExchangeRatesView, "View exchange rates", MasterDataModule,
            "See the Exchange Rates page and the latest rates.", 220),
        new(MasterData.ExchangeRatesCreate, "Create exchange rates", MasterDataModule,
            "Enter official, non-official and market rates.", 230),
        new(MasterData.ExchangeRatesEdit, "Edit exchange rates", MasterDataModule,
            "Correct entered rates.", 240),
        new(MasterData.ExchangeRatesDelete, "Delete exchange rates", MasterDataModule,
            "Remove wrongly entered rates.", 250),

        new(MasterData.ItemFamiliesView, "View item families", MasterDataModule,
            "See the Item Families tree.", 260),
        new(MasterData.ItemFamiliesCreate, "Create item families", MasterDataModule,
            "Add root and child families.", 270),
        new(MasterData.ItemFamiliesEdit, "Edit item families", MasterDataModule,
            "Change family details, move families and activate / deactivate them.", 280),
        new(MasterData.ItemFamiliesDelete, "Delete item families", MasterDataModule,
            "Delete families without children that are not assigned to items.", 290),

        new(MasterData.BrandsView, "View brands", MasterDataModule,
            "See the Brands list.", 300),
        new(MasterData.BrandsCreate, "Create brands", MasterDataModule,
            "Add new brands.", 310),
        new(MasterData.BrandsEdit, "Edit brands", MasterDataModule,
            "Change brand details and activate / deactivate them.", 320),
        new(MasterData.BrandsDelete, "Delete brands", MasterDataModule,
            "Delete brands that are not assigned to items.", 330),

        new(MasterData.UnitTypesView, "View unit types", MasterDataModule,
            "See the Unit Types list.", 340),
        new(MasterData.UnitTypesCreate, "Create unit types", MasterDataModule,
            "Add new unit types.", 350),
        new(MasterData.UnitTypesEdit, "Edit unit types", MasterDataModule,
            "Change unit types and activate / deactivate them.", 360),
        new(MasterData.UnitTypesDelete, "Delete unit types", MasterDataModule,
            "Delete unit types not used by items.", 370),

        new(Inventory.ItemsView, "View items", InventoryModule,
            "See the Item Definition list and item details.", 400),
        new(Inventory.ItemsCreate, "Create items", InventoryModule,
            "Add new items with units and attachments.", 410),
        new(Inventory.ItemsEdit, "Edit items", InventoryModule,
            "Change items, units, attachments and status.", 420),
        new(Inventory.ItemsDelete, "Delete items", InventoryModule,
            "Delete items not referenced by transactions.", 430),
    ];
}
