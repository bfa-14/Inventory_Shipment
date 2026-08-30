using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Security;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers;

/// <summary>Read-only security reporting.</summary>
[ApiController]
[Route("api/security")]
[Produces("application/json")]
public sealed class SecurityController : ControllerBase
{
    private readonly ILoginAuditService _loginAuditService;

    public SecurityController(ILoginAuditService loginAuditService)
    {
        _loginAuditService = loginAuditService;
    }

    /// <summary>Sign-in attempts, newest first.</summary>
    [HttpGet("login-audit")]
    [HasPermission(Permissions.Security.AuditView)]
    [ProducesResponseType<IReadOnlyList<LoginAuditDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<LoginAuditDto>>> GetLoginAudit(
        [FromQuery] LoginAuditQuery query, CancellationToken cancellationToken)
    {
        var result = await _loginAuditService.GetAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }
}
