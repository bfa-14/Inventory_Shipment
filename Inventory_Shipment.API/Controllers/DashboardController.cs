using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Dashboard;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers;

/// <summary>The Dashboard's figures.</summary>
[ApiController]
[Route("api/dashboard")]
[Produces("application/json")]
public sealed class DashboardController : ControllerBase
{
    private readonly IDashboardService _dashboard;

    public DashboardController(IDashboardService dashboard)
    {
        _dashboard = dashboard;
    }

    /// <summary>
    /// Key figures and "needs attention" lists for one branch (none = all) and one period, for a reader who
    /// may open the Dashboard (script 74): each section is left out (null) unless they may also open the
    /// screen it comes from.
    /// </summary>
    [HttpGet("summary")]
    [HasPermission(Permissions.Dashboard.View)]
    [ProducesResponseType<DashboardSummaryDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<DashboardSummaryDto>> GetSummary(
        [FromQuery] DashboardSummaryQuery query, CancellationToken cancellationToken)
    {
        var result = await _dashboard.GetSummaryAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
