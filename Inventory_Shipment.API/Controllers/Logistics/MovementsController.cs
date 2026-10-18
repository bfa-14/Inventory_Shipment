using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
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
    [HasPermission(Permissions.Containers.MovementsView)]
    [ProducesResponseType<PagedResult<MovementListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<MovementListDto>>> Search(
        [FromQuery] MovementQuery query, CancellationToken cancellationToken)
    {
        var result = await _movements.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The filtered list, every page, as a workbook.</summary>
    [HttpGet("export")]
    [HasPermission(Permissions.Containers.MovementsView)]
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
    /// save would refuse (canAdd false, reason). At most 5,000 a page (script 78). 400 VALIDATION without fromPlaceId.
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
    /// is saved. 400 VALIDATION without a number or above 10,000.
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

    /// <summary>
    /// (80) The planned movements a container can join ("Add to a movement..." on its page), newest first: created after
    /// its latest movement and passing the checks the save makes for it at their From. 404 NOT_FOUND without the container.
    /// </summary>
    [HttpGet("join-candidates")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<IReadOnlyList<MovementJoinCandidateDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<MovementJoinCandidateDto>>> JoinCandidates(
        [FromQuery] int containerId, CancellationToken cancellationToken)
    {
        var result = await _movements.JoinCandidatesAsync(containerId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    // View Movements OR View Containers: a container's page reads the movements it travels with.
    [HttpGet("{id:int}")]
    [Authorize]
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
    /// created (default SEA, from their common port of loading to their common port of destination; a container
    /// that moved leaves from where it is - script 80) and started unless startNow is false; vessel, voyage, B/L and
    /// ETA copied to the containers.
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

    /// <summary>
    /// 409 CONTAINER_NOT_AT_FROM when a container, added or kept, is not at the From, or already travelled further with
    /// a later movement (script 80). A movement in progress: 400 VALIDATION for a start date in the future, 409
    /// START_BEFORE_PREVIOUS_LEG when it is before the previous leg of one of its containers ended (script 80).
    /// </summary>
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
    /// PREVIOUS_MOVEMENT_OPEN when its previous movement is not completed, CONTAINER_NOT_AT_FROM when it ends elsewhere,
    /// START_BEFORE_PREVIOUS_LEG (script 80) when the date is before that previous movement ended; 400 VALIDATION for a
    /// date in the future.
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

    /// <summary>date = end date (default today); 400 VALIDATION for a date in the future (script 80).</summary>
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

    /// <summary>
    /// (82) Only some containers arrived: { containerIds, date, rowVersion } - the ticked containers (some of the movement's,
    /// not all) leave the movement in progress for their own movement, a copy with the same header and start date, which
    /// is completed on the date (a Delivery drafts their goods receipts, as Complete does); the others stay on it, in
    /// progress. The date is checked before anything is split. 200 { ok, code, message, originalMovementId,
    /// originalMovementNo, remainingContainerCount, movement, warnings } - ok false when split but its completion was
    /// refused (the message says so, movement is the new one in progress). Nothing split: 400 VALIDATION (no container, one
    /// not on the movement, a date in the future or before the start), 404 NOT_FOUND, 409 CONCURRENCY (changed since) or
    /// INVALID_STATUS (not in progress, every container ticked, a container with a later leg).
    /// </summary>
    [HttpPost("{id:int}/complete-some")]
    [HasPermission(Permissions.Containers.MovementsManage)]
    [ProducesResponseType<MovementSplitResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<MovementSplitResultDto>> CompleteSome(
        int id, [FromBody] CompleteSomeContainersRequest request, CancellationToken cancellationToken)
    {
        var result = await _movements.CompleteSomeAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
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
