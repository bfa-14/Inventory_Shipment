using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// Ports, border posts and inland places: loading, destination and the places of the route events.
/// One "manage" permission for the list and the writes; the LOOKUP is open to any signed-in user,
/// because the container page picks from it.
/// </summary>
[ApiController]
[Route("api/masterdata/ports")]
[Produces("application/json")]
public sealed class PortsController : ControllerBase
{
    private readonly IPortService _ports;

    public PortsController(IPortService ports)
    {
        _ports = ports;
    }

    [HttpGet]
    [HasPermission(Permissions.MasterData.PortsManage)]
    [ProducesResponseType<PagedResult<PortDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<PortDto>>> Search([FromQuery] PortQuery query, CancellationToken cancellationToken)
    {
        var result = await _ports.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<PortLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<PortLookupDto>>> Lookup(
        [FromQuery] string? kind = null, [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _ports.LookupAsync(kind, activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.PortsManage)]
    [ProducesResponseType<PortDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PortDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _ports.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A code already in use fails with 409 DUPLICATE_CODE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.PortsManage)]
    [ProducesResponseType<PortDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PortDto>> Create([FromBody] SavePortRequest request, CancellationToken cancellationToken)
    {
        var result = await _ports.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.PortsManage)]
    [ProducesResponseType<PortDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PortDto>> Update(int id, [FromBody] SavePortRequest request, CancellationToken cancellationToken)
    {
        var result = await _ports.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps a used row readable on old containers; deleting is for one nothing has used.</summary>
    [HttpPost("{id:int}/set-active")]
    [HasPermission(Permissions.MasterData.PortsManage)]
    [ProducesResponseType<PortDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PortDto>> SetActive(
        int id, [FromBody] SetLogisticsMasterActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _ports.SetActiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 IN_USE when containers use it.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.PortsManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _ports.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
