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

    /// <summary>
    /// Selling: invoices and what may be done to their lines.
    ///
    /// PRICE OVERRIDE IS A SEPARATE PERMISSION, not part of importing. Anybody who takes invoices may
    /// import lines; deciding that a line is worth a different price than the price list says is a
    /// commercial decision, and it is the one thing in an import file that changes what the customer
    /// is charged. Someone holding only the first gets the system price and a warning saying so.
    /// </summary>
    /// <summary>
    /// Configuration a business owner changes once and then leaves alone — numbering, document
    /// behaviour. Kept out of the Inventory module deliberately: the people who post stock are not
    /// the people who decide what a document number looks like.
    /// </summary>
    public static class Configuration
    {
        public const string DocumentTypesManage = "inventory.documenttypes.manage";
    }

    public static class Sales
    {
        public const string InvoicesImport = "sales.invoices.import";
        public const string InvoicesPriceOverride = "sales.invoices.priceoverride";
        public const string InvoicesView = "sales.invoices.view";
        public const string InvoicesCreate = "sales.invoices.create";
        public const string InvoicesPost = "sales.invoices.post";
        public const string InvoicesCancel = "sales.invoices.cancel";
        public const string InvoicesDelete = "sales.invoices.delete";
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
        public const string PriceListsView = "masterdata.pricelists.view";
        public const string PriceListsCreate = "masterdata.pricelists.create";
        public const string PriceListsEdit = "masterdata.pricelists.edit";
        public const string PriceListsDelete = "masterdata.pricelists.delete";
        public const string PartiesView = "masterdata.parties.view";
        public const string PartiesCreate = "masterdata.parties.create";
        public const string PartiesEdit = "masterdata.parties.edit";
        public const string PartiesDelete = "masterdata.parties.delete";
    }

    public static class Inventory
    {
        public const string ItemsView = "inventory.items.view";
        public const string ItemsCreate = "inventory.items.create";
        public const string ItemsEdit = "inventory.items.edit";
        public const string ItemsDelete = "inventory.items.delete";

        /* THE FIVE VERBS OF A DOCUMENT, and they are five permissions rather than one because they
           are five different jobs. A storekeeper writes drafts; a supervisor posts them, which is the
           moment stock actually moves; cancelling reverses a posted document and is rarer still. In
           and Out are separate sets for the same reason a shop separates receiving from issuing. */
        public const string StockInView = "inventory.stockin.view";
        public const string StockInCreate = "inventory.stockin.create";
        public const string StockInPost = "inventory.stockin.post";
        public const string StockInCancel = "inventory.stockin.cancel";
        public const string StockInDelete = "inventory.stockin.delete";

        public const string StockOutView = "inventory.stockout.view";
        public const string StockOutCreate = "inventory.stockout.create";
        public const string StockOutPost = "inventory.stockout.post";
        public const string StockOutCancel = "inventory.stockout.cancel";
        public const string StockOutDelete = "inventory.stockout.delete";

        /// <summary>The shortage report, and the "Create Purchase Order" it offers (which also needs purchase.orders.create).</summary>
        public const string ShortagesView = "inventory.shortages.view";
    }

    /// <summary>
    /// Buying: the three documents of the Purchase family, each with the same five verbs.
    ///
    /// THREE SETS FOR ONE ENGINE. An order commits nothing but a promise; an invoice moves stock in and
    /// sets the cost every later sale is valued at; a return moves stock out. Different people sign
    /// each, so each is its own permission even though one page serves all three.
    /// </summary>
    public static class Purchase
    {
        public const string OrdersView = "purchase.orders.view";
        public const string OrdersCreate = "purchase.orders.create";
        public const string OrdersPost = "purchase.orders.post";
        public const string OrdersCancel = "purchase.orders.cancel";
        public const string OrdersDelete = "purchase.orders.delete";

        public const string InvoicesView = "purchase.invoices.view";
        public const string InvoicesCreate = "purchase.invoices.create";
        public const string InvoicesPost = "purchase.invoices.post";
        public const string InvoicesCancel = "purchase.invoices.cancel";
        public const string InvoicesDelete = "purchase.invoices.delete";

        public const string ReturnsView = "purchase.returns.view";
        public const string ReturnsCreate = "purchase.returns.create";
        public const string ReturnsPost = "purchase.returns.post";
        public const string ReturnsCancel = "purchase.returns.cancel";
        public const string ReturnsDelete = "purchase.returns.delete";
    }

    private const string SecurityModule = "Security";
    private const string SalesModule = "Sales";
    private const string ConfigurationModule = "Configuration";
    private const string MasterDataModule = "Master Data";
    private const string InventoryModule = "Inventory";
    private const string PurchaseModule = "Purchase";

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

        new(MasterData.PriceListsView, "View price lists", MasterDataModule,
            "See the Price Lists page.", 440),
        new(MasterData.PriceListsCreate, "Create price lists", MasterDataModule,
            "Add new price lists.", 450),
        new(MasterData.PriceListsEdit, "Edit price lists", MasterDataModule,
            "Change price lists and activate / deactivate them.", 460),
        new(MasterData.PriceListsDelete, "Delete price lists", MasterDataModule,
            "Delete empty price lists.", 470),

        new(MasterData.PartiesView, "View parties", MasterDataModule,
            "See the Parties list (suppliers, clients, salesmen, employees).", 520),
        new(MasterData.PartiesCreate, "Create parties", MasterDataModule,
            "Add new parties.", 530),
        new(MasterData.PartiesEdit, "Edit parties", MasterDataModule,
            "Change parties and activate / deactivate them.", 540),
        new(MasterData.PartiesDelete, "Delete parties", MasterDataModule,
            "Delete parties never referenced by transactions.", 550),

        new(Inventory.ItemsView, "View items", InventoryModule,
            "See the Item Definition list and item details.", 400),
        new(Inventory.ItemsCreate, "Create items", InventoryModule,
            "Add new items with units and attachments.", 410),
        new(Inventory.ItemsEdit, "Edit items", InventoryModule,
            "Change items, units, attachments and status.", 420),
        new(Inventory.ItemsDelete, "Delete items", InventoryModule,
            "Delete items not referenced by transactions.", 430),

        new(Inventory.StockInView, "View Inventory In", InventoryModule,
            "See Inventory In documents.", 700),
        new(Inventory.StockInCreate, "Create Inventory In", InventoryModule,
            "Create and edit draft Inventory In documents.", 710),
        new(Inventory.StockInPost, "Post Inventory In", InventoryModule,
            "Post Inventory In documents (adds stock).", 720),
        new(Inventory.StockInCancel, "Cancel Inventory In", InventoryModule,
            "Cancel posted Inventory In documents (reversal).", 730),
        new(Inventory.StockInDelete, "Delete Inventory In", InventoryModule,
            "Delete draft Inventory In documents.", 740),

        new(Inventory.StockOutView, "View Inventory Out", InventoryModule,
            "See Inventory Out documents.", 760),
        new(Inventory.StockOutCreate, "Create Inventory Out", InventoryModule,
            "Create and edit draft Inventory Out documents.", 770),
        new(Inventory.StockOutPost, "Post Inventory Out", InventoryModule,
            "Post Inventory Out documents (removes stock).", 780),
        new(Inventory.StockOutCancel, "Cancel Inventory Out", InventoryModule,
            "Cancel posted Inventory Out documents (reversal).", 790),
        new(Inventory.StockOutDelete, "Delete Inventory Out", InventoryModule,
            "Delete draft Inventory Out documents.", 800),

        new(Configuration.DocumentTypesManage, "Manage document types", ConfigurationModule,
            "Change numbering and behaviour of document types.", 900),

        new(Inventory.ShortagesView, "View Shortages", InventoryModule,
            "See the shortage report and create purchase orders from it.", 950),

        new(Purchase.OrdersView, "View Purchase Orders", PurchaseModule,
            "See purchase orders.", 1000),
        new(Purchase.OrdersCreate, "Create Purchase Orders", PurchaseModule,
            "Create and edit draft purchase orders.", 1010),
        new(Purchase.OrdersPost, "Post Purchase Orders", PurchaseModule,
            "Confirm purchase orders (assigns number, stock becomes incoming) and close open ones.", 1020),
        new(Purchase.OrdersCancel, "Cancel Purchase Orders", PurchaseModule,
            "Cancel confirmed purchase orders.", 1030),
        new(Purchase.OrdersDelete, "Delete Purchase Orders", PurchaseModule,
            "Delete draft purchase orders.", 1040),

        new(Purchase.InvoicesView, "View Purchase Invoices", PurchaseModule,
            "See purchase invoices.", 1060),
        new(Purchase.InvoicesCreate, "Create Purchase Invoices", PurchaseModule,
            "Create and edit draft purchase invoices.", 1070),
        new(Purchase.InvoicesPost, "Post Purchase Invoices", PurchaseModule,
            "Post purchase invoices (adds stock, sets costs).", 1080),
        new(Purchase.InvoicesCancel, "Cancel Purchase Invoices", PurchaseModule,
            "Cancel posted purchase invoices (stock reversal).", 1090),
        new(Purchase.InvoicesDelete, "Delete Purchase Invoices", PurchaseModule,
            "Delete draft purchase invoices.", 1100),

        new(Purchase.ReturnsView, "View Purchase Returns", PurchaseModule,
            "See purchase returns.", 1120),
        new(Purchase.ReturnsCreate, "Create Purchase Returns", PurchaseModule,
            "Create and edit draft purchase returns.", 1130),
        new(Purchase.ReturnsPost, "Post Purchase Returns", PurchaseModule,
            "Post purchase returns (removes stock).", 1140),
        new(Purchase.ReturnsCancel, "Cancel Purchase Returns", PurchaseModule,
            "Cancel posted purchase returns (stock reversal).", 1150),
        new(Purchase.ReturnsDelete, "Delete Purchase Returns", PurchaseModule,
            "Delete draft purchase returns.", 1160),

        new(Sales.InvoicesImport, "Import invoice items", SalesModule,
            "Import invoice lines from an Excel file.", 600),
        new(Sales.InvoicesPriceOverride, "Override selling price", SalesModule,
            "Accept a manual unit price instead of the price list price.", 610),

        new(Sales.InvoicesView, "View Sales Invoices", SalesModule,
            "See sales invoices.", 620),
        new(Sales.InvoicesCreate, "Create Sales Invoices", SalesModule,
            "Create and edit draft sales invoices.", 630),
        new(Sales.InvoicesPost, "Post Sales Invoices", SalesModule,
            "Post sales invoices (removes stock, assigns number).", 640),
        new(Sales.InvoicesCancel, "Cancel Sales Invoices", SalesModule,
            "Cancel posted sales invoices (stock reversal).", 650),
        new(Sales.InvoicesDelete, "Delete Sales Invoices", SalesModule,
            "Delete draft sales invoices.", 660),
    ];
}
