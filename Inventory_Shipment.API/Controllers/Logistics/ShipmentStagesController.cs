using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// (111) Shipment stages: the stages a container moves through (kept by an administrator), and the way it moves on -
/// "Update stage…" for ticked containers and the import of the forwarder's list. Moving a container makes, starts and
/// completes its movements with the movement procedures, and an Offload stage posts its goods receipt.
/// </summary>
[ApiController]
[Route("api/logistics/shipment-stages")]
[Produces("application/json")]
public sealed class ShipmentStagesController : ControllerBase
{
    private readonly IShipmentStageService _stages;

    public ShipmentStagesController(IShipmentStageService stages)
    {
        _stages = stages;
    }

    /// <summary>The stages in their order (activeOnly: the ones a container can move to).</summary>
    [HttpGet]
    [ProducesResponseType<IReadOnlyList<ShipmentStageDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ShipmentStageDto>>> List([FromQuery] bool activeOnly, CancellationToken cancellationToken)
    {
        var result = await _stages.ListAsync(activeOnly, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost]
    [HasPermission(Permissions.MasterData.ShipmentStagesManage)]
    [ProducesResponseType<ShipmentStageDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ShipmentStageDto>> Create([FromBody] SaveShipmentStageRequest request, CancellationToken cancellationToken)
    {
        var result = await _stages.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.ShipmentStagesManage)]
    [ProducesResponseType<ShipmentStageDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ShipmentStageDto>> Update(
        int id, [FromBody] SaveShipmentStageRequest request, CancellationToken cancellationToken)
    {
        var result = await _stages.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.ShipmentStagesManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _stages.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.IsSuccess ? NoContent() : this.ToProblem(result);
    }

    /// <summary>How many containers stand at each stage, and the ones whose route the stages do not describe.</summary>
    [HttpGet("check")]
    [ProducesResponseType<ShipmentStageCheckDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<ShipmentStageCheckDto>> Check(CancellationToken cancellationToken)
    {
        var result = await _stages.CheckAsync(User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>What moving the containers to the stage does to each, or why it cannot. Nothing is saved.</summary>
    [HttpPost("preview")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<IReadOnlyList<ShipmentStagePreviewRowDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<ShipmentStagePreviewRowDto>>> Preview(
        [FromBody] ShipmentStagePreviewRequest request, CancellationToken cancellationToken)
    {
        var result = await _stages.PreviewAsync(request, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The container each number of the forwarder's list names (by container no. or ref).</summary>
    [HttpPost("match")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<IReadOnlyList<ShipmentStageMatchRowDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<ShipmentStageMatchRowDto>>> Match(
        [FromBody] ShipmentStageMatchRequest request, CancellationToken cancellationToken)
    {
        var result = await _stages.MatchNumbersAsync(request, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Moves each container to its stage on its date: one result per container, in order - moved, already there or
    /// refused with the reason; 200 whatever each gave. 400 VALIDATION for a request that cannot be read.
    /// </summary>
    [HttpPost("apply")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<ApplyShipmentStageResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<ApplyShipmentStageResultDto>> Apply(
        [FromBody] ApplyShipmentStageRequest request, CancellationToken cancellationToken)
    {
        var result = await _stages.ApplyAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
