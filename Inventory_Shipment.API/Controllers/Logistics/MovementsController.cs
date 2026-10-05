using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Shipment movements (MOV-yyyy-nnnnnn): one leg of the route carrying one or more containers.
/// Starting and completing a movement is what moves the containers' status, milestone dates and
/// location — by the stage of its type.
/// </summary>
[ApiController]
[Route("api/logistics/movements")]
[Produces("application/json")]
public sealed class MovementsController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IMovementService _movements;

    public MovementsController(IMovementService movements)
    {
        _movements = movements;
    }

    [HttpGet]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<PagedResult<MovementListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<MovementListDto>>> Search(
        [FromQuery] MovementQuery query, CancellationToken cancellationToken)
    {
        var result = await _movements.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The filtered list, every page, as a workbook.</summary>
    [HttpGet("export")]
    [HasPermission(Permissions.Containers.View)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] MovementQuery query, CancellationToken cancellationToken)
    {
        var result = await _movements.ExportAsync(query, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// The containers a movement can take (movementId empty = a new one) for the From on the page, saved or not:
    /// at the From — where their previous movement ends — or never moved. includeBlocked also lists the ones the
    /// save would refuse (canAdd false, reason). At most 200 a page. 400 VALIDATION without fromPlaceId.
    /// </summary>
    [HttpGet("container-candidates")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<PagedResult<MovementContainerCandidateDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PagedResult<MovementContainerCandidateDto>>> ContainerCandidates(
        [FromQuery] MovementContainerCandidateQuery query, CancellationToken cancellationToken)
    {
        var result = await _movements.ContainerCandidatesAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Container numbers or refs (typed, pasted or read from a file) matched for a movement: one row per number in
    /// the order given — Ready, AlreadyOnMovement, NotFound, Ambiguous, Blocked or Duplicate, with the reason. Nothing
    /// is saved. 400 VALIDATION without a number or above 500.
    /// </summary>
    [HttpPost("match-containers")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<IReadOnlyList<MovementContainerMatchDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<MovementContainerMatchDto>>> MatchContainers(
        [FromBody] MatchMovementContainersRequest request, CancellationToken cancellationToken)
    {
        var result = await _movements.MatchContainersAsync(request, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<MovementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<MovementDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _movements.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 CONTAINER_NOT_AT_FROM when a container is elsewhere: its previous movement ends at another place.</summary>
    [HttpPost]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<MovementDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementDto>> Create(
        [FromBody] SaveMovementRequest request, CancellationToken cancellationToken)
    {
        var result = await _movements.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>
    /// One movement for the chosen containers: drafts confirmed (with containers.confirm), the movement
    /// created (default SEA, from their common port of loading to their common port of destination) and
    /// started unless startNow is false; vessel, voyage, B/L and ETA copied to the containers.
    /// 409 CONTAINER_BUSY names a container travelling with another movement.
    /// </summary>
    [HttpPost("ship-containers")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<ShippedMovementDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ShippedMovementDto>> ShipContainers(
        [FromBody] ShipContainersRequest request, CancellationToken cancellationToken)
    {
        var result = await _movements.ShipContainersAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>409 CONTAINER_NOT_AT_FROM when a container, added or kept, is not at the From.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<MovementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementDto>> Update(
        int id, [FromBody] SaveMovementRequest request, CancellationToken cancellationToken)
    {
        var result = await _movements.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// date = start date (default today). 409 CONTAINER_BUSY when a container travels with another movement in progress,
    /// PREVIOUS_MOVEMENT_OPEN when its previous movement is not completed, CONTAINER_NOT_AT_FROM when it ends elsewhere.
    /// </summary>
    [HttpPost("{id:int}/start")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<MovementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementDto>> Start(
        int id, [FromBody] MovementStatusRequest? request, CancellationToken cancellationToken)
    {
        var result = await _movements.StartAsync(
            id, request ?? new MovementStatusRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>date = end date (default today).</summary>
    [HttpPost("{id:int}/complete")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<MovementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementDto>> Complete(
        int id, [FromBody] MovementStatusRequest? request, CancellationToken cancellationToken)
    {
        var result = await _movements.CompleteAsync(
            id, request ?? new MovementStatusRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<MovementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementDto>> Cancel(
        int id, [FromBody] MovementStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _movements.CancelAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Planned movements only.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _movements.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
