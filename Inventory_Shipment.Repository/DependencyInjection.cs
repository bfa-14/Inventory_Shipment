using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Implementations;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Inventory_Shipment.Repository;

public static class DependencyInjection
{
    /// <summary>
    /// Registers Dapper/SQL Server data access. The API passes the connection string and
    /// optional "Database" settings through <paramref name="configure"/>.
    /// </summary>
    public static IServiceCollection AddRepositoryLayer(this IServiceCollection services, Action<DatabaseOptions> configure)
    {
        services.Configure(configure);
        services.TryAddSingleton<ISqlConnectionFactory, SqlConnectionFactory>();
        services.TryAddSingleton<IDatabaseInitializer, DatabaseInitializer>();

        services.TryAddScoped<IUserRepository, UserRepository>();
        services.TryAddScoped<IRefreshTokenRepository, RefreshTokenRepository>();
        services.TryAddScoped<ILoginAuditRepository, LoginAuditRepository>();
        services.TryAddScoped<IRoleRepository, RoleRepository>();
        services.TryAddScoped<IPermissionRepository, PermissionRepository>();
        services.TryAddScoped<IBranchRepository, BranchRepository>();
        services.TryAddScoped<IWarehouseRepository, WarehouseRepository>();
        services.TryAddScoped<ICurrencyRepository, CurrencyRepository>();
        services.TryAddScoped<IExchangeRateRepository, ExchangeRateRepository>();
        services.TryAddScoped<IItemFamilyRepository, ItemFamilyRepository>();
        services.TryAddScoped<IBrandRepository, BrandRepository>();
        services.TryAddScoped<IUnitTypeRepository, UnitTypeRepository>();
        services.TryAddScoped<IPriceListRepository, PriceListRepository>();
        services.TryAddScoped<IPartyRepository, PartyRepository>();
        services.TryAddScoped<IItemRepository, ItemRepository>();
        services.TryAddScoped<IInvoiceImportRepository, InvoiceImportRepository>();
        services.TryAddScoped<IStockDocumentRepository, StockDocumentRepository>();
        services.TryAddScoped<ISalesDocumentRepository, SalesDocumentRepository>();

        return services;
    }
}
