using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Roles;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers;

/// <summary>
/// The permission catalog. It is defined by the application code and synced on start-up, so it is
/// read-only here: permissions are granted to roles on the Roles endpoints.
/// </summary>
[ApiController]
[Route("api/permissions")]
[Produces("application/json")]
public sealed class PermissionsController : ControllerBase
{
    private readonly IPermissionService _permissionService;

    public PermissionsController(IPermissionService permissionService)
    {
        _permissionService = permissionService;
    }

    [HttpGet]
    [HasPermission(Permissions.Security.PermissionsView)]
    [ProducesResponseType<IReadOnlyList<PermissionModuleDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<PermissionModuleDto>>> GetCatalog(CancellationToken cancellationToken)
    {
        var result = await _permissionService.GetCatalogAsync(cancellationToken);
        return result.ToActionResult(this);
    }
}
