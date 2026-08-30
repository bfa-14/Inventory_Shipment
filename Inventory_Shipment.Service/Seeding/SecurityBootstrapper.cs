using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Seeding;

/// <summary>
/// Keeps security.Permissions in step with <see cref="Permissions.All"/>. The application code owns the
/// catalog; the database only stores it (and the system-role grants the procedure maintains).
/// </summary>
public sealed class SecurityBootstrapper : ISecurityBootstrapper
{
    private readonly IPermissionRepository _permissions;
    private readonly ILogger<SecurityBootstrapper> _logger;

    public SecurityBootstrapper(IPermissionRepository permissions, ILogger<SecurityBootstrapper> logger)
    {
        _permissions = permissions;
        _logger = logger;
    }

    public async Task SyncPermissionCatalogAsync(CancellationToken cancellationToken = default)
    {
        await _permissions.SyncCatalogAsync(Permissions.All, cancellationToken);
        _logger.LogInformation("Permission catalog synced ({Count} permission(s)).", Permissions.All.Count);
    }
}
