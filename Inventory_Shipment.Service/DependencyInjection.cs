using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Implementations;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Security;
using Inventory_Shipment.Service.Seeding;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Inventory_Shipment.Service;

public static class DependencyInjection
{
    /// <summary>
    /// Registers the business services. Options (JwtOptions, SecurityOptions, SeedOptions) are bound
    /// by the host from configuration before calling this.
    /// </summary>
    public static IServiceCollection AddServiceLayer(this IServiceCollection services)
    {
        services.TryAddSingleton(TimeProvider.System);

        services.TryAddSingleton<IPasswordHasher, Argon2PasswordHasher>();
        services.TryAddSingleton<IPasswordPolicy, PasswordPolicy>();
        services.TryAddSingleton<ITokenService, JwtTokenService>();

        services.TryAddScoped<IAuthService, AuthService>();
        services.TryAddScoped<IUserService, UserService>();
        services.TryAddScoped<IRoleService, RoleService>();
        services.TryAddScoped<IPermissionService, PermissionService>();
        services.TryAddScoped<ILoginAuditService, LoginAuditService>();
        services.TryAddScoped<IBranchService, BranchService>();
        services.TryAddScoped<IWarehouseService, WarehouseService>();
        services.TryAddScoped<ICurrencyService, CurrencyService>();
        services.TryAddScoped<IExchangeRateService, ExchangeRateService>();
        services.TryAddScoped<IItemFamilyService, ItemFamilyService>();
        services.TryAddScoped<IBrandService, BrandService>();
        services.TryAddScoped<IUnitTypeService, UnitTypeService>();
        services.TryAddScoped<IPriceListService, PriceListService>();
        services.TryAddScoped<IPartyService, PartyService>();
        services.TryAddScoped<IItemService, ItemService>();

        // Singletons: both are stateless workbook readers/writers holding nothing per request, and a
        // new one per import would be an allocation for nothing.
        services.TryAddSingleton<InvoiceImportParser>();
        services.TryAddSingleton<InvoiceImportWorkbooks>();
        services.TryAddScoped<IInvoiceImportService, InvoiceImportService>();
        services.TryAddScoped<IStockDocumentService, StockDocumentService>();
        services.TryAddScoped<ISalesInvoiceService, SalesInvoiceService>();
        services.TryAddScoped<IPurchaseDocumentService, PurchaseDocumentService>();
        services.TryAddScoped<IShortageDocumentService, ShortageDocumentService>();
        services.TryAddScoped<IChargeTypeService, ChargeTypeService>();
        services.TryAddScoped<ILandedCostAdjustmentService, LandedCostAdjustmentService>();
        services.TryAddScoped<ICostingReportService, CostingReportService>();
        services.TryAddScoped<IContainerService, ContainerService>();
        services.TryAddScoped<IContainerTypeService, ContainerTypeService>();
        services.TryAddScoped<IPortService, PortService>();
        services.TryAddScoped<IMovementTypeService, MovementTypeService>();
        services.TryAddScoped<IMovementService, MovementService>();
        services.TryAddScoped<IContainerChargeService, ContainerChargeService>();
        services.TryAddScoped<IAttachmentTypeService, AttachmentTypeService>();
        services.TryAddScoped<ISecurityBootstrapper, SecurityBootstrapper>();
        services.TryAddScoped<IDataSeeder, AdminSeeder>();

        return services;
    }
}
