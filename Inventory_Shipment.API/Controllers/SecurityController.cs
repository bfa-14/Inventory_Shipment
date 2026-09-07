using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Security;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers;

/// <summary>Read-only security reporting and the users dropdown.</summary>
[ApiController]
[Route("api/security")]
[Produces("application/json")]
public sealed class SecurityController : ControllerBase
{
    private readonly ILoginAuditService _loginAuditService;
    private readonly IUserService _userService;

    public SecurityController(ILoginAuditService loginAuditService, IUserService userService)
    {
        _loginAuditService = loginAuditService;
        _userService = userService;
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

    /// <summary>
    /// Users for a "pick a user" dropdown - id, username, full name and status, nothing else. Any
    /// signed-in user may read it: forms that link a record to the user it belongs to need it (the
    /// Parties form links a salesman or employee to the user they sign in as), and administering
    /// users is a separate, guarded concern.
    /// </summary>
    [HttpGet("users/lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<UserLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<UserLookupDto>>> UserLookup(
        [FromQuery] string? search = null, [FromQuery] bool activeOnly = true,
        [FromQuery] int? includeId = null, [FromQuery] int top = 50,
        CancellationToken cancellationToken = default)
    {
        var result = await _userService.LookupAsync(search, activeOnly, includeId, top, cancellationToken);
        return result.ToActionResult(this);
    }
}
