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
/// Container types (20GP, 40HC...) and their capacity in units, copied onto a new container.
/// One "manage" permission for the list and the writes; the LOOKUP is open to any signed-in user,
/// because the container page picks from it.
/// </summary>
[ApiController]
[Route("api/masterdata/container-types")]
[Produces("application/json")]
public sealed class ContainerTypesController : ControllerBase
{
    private readonly IContainerTypeService _containerTypes;

    public ContainerTypesController(IContainerTypeService containerTypes)
    {
        _containerTypes = containerTypes;
    }

    [HttpGet]
    [HasPermission(Permissions.MasterData.ContainerTypesManage)]
    [ProducesResponseType<PagedResult<ContainerTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ContainerTypeDto>>> Search([FromQuery] ContainerTypeQuery query, CancellationToken cancellationToken)
    {
        var result = await _containerTypes.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<ContainerTypeLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ContainerTypeLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _containerTypes.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.ContainerTypesManage)]
    [ProducesResponseType<ContainerTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ContainerTypeDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _containerTypes.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A code already in use fails with 409 DUPLICATE_CODE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.ContainerTypesManage)]
    [ProducesResponseType<ContainerTypeDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerTypeDto>> Create([FromBody] SaveContainerTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _containerTypes.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.ContainerTypesManage)]
    [ProducesResponseType<ContainerTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerTypeDto>> Update(int id, [FromBody] SaveContainerTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _containerTypes.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps a used row readable on old containers; deleting is for one nothing has used.</summary>
    [HttpPost("{id:int}/set-active")]
    [HasPermission(Permissions.MasterData.ContainerTypesManage)]
    [ProducesResponseType<ContainerTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerTypeDto>> SetActive(
        int id, [FromBody] SetLogisticsMasterActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _containerTypes.SetActiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 IN_USE when containers use it.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.ContainerTypesManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _containerTypes.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
