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
        services.TryAddScoped<ISecurityBootstrapper, SecurityBootstrapper>();
        services.TryAddScoped<IDataSeeder, AdminSeeder>();

        return services;
    }
}
