using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// Movement types: the legs a container's route is made of, each with the STAGE that moves the
/// container status. One "manage" permission for the list and the writes; the LOOKUP needs
/// containers.view, because the movement pages pick from it.
/// </summary>
[ApiController]
[Route("api/masterdata/movement-types")]
[Produces("application/json")]
public sealed class MovementTypesController : ControllerBase
{
    private readonly IMovementTypeService _types;

    public MovementTypesController(IMovementTypeService types)
    {
        _types = types;
    }

    [HttpGet]
    [HasPermission(Permissions.MasterData.MovementTypesManage)]
    [ProducesResponseType<PagedResult<MovementTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<MovementTypeDto>>> Search(
        [FromQuery] MovementTypeQuery query, CancellationToken cancellationToken)
    {
        var result = await _types.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<IReadOnlyList<MovementTypeLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<MovementTypeLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _types.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.MovementTypesManage)]
    [ProducesResponseType<MovementTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<MovementTypeDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _types.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A code already in use fails with 409 DUPLICATE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.MovementTypesManage)]
    [ProducesResponseType<MovementTypeDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementTypeDto>> Create(
        [FromBody] SaveMovementTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _types.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>409 IN_USE when the stage of a type used by movements is changed.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.MovementTypesManage)]
    [ProducesResponseType<MovementTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementTypeDto>> Update(
        int id, [FromBody] SaveMovementTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _types.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps a used row readable on old movements; deleting is for one nothing has used.</summary>
    [HttpPost("{id:int}/set-active")]
    [HasPermission(Permissions.MasterData.MovementTypesManage)]
    [ProducesResponseType<MovementTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementTypeDto>> SetActive(
        int id, [FromBody] SetLogisticsMasterActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _types.SetActiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 IN_USE when movements use it.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.MovementTypesManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _types.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
