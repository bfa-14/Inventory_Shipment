using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Container charges — freight, clearing, insurance — typed once for one or several containers and
/// divided over their lines: the real cost of every item. Posting moves the cost; a charge posted
/// after the offload becomes a cost adjustment.
/// </summary>
[ApiController]
[Route("api/logistics/container-charges")]
[Produces("application/json")]
public sealed class ContainerChargesController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IContainerChargeService _charges;

    public ContainerChargesController(IContainerChargeService charges)
    {
        _charges = charges;
    }

    /// <summary>One page and totalAmountBase = the total of the whole filter.</summary>
    [HttpGet]
    [HasPermission(Permissions.Containers.ChargesView)]
    [ProducesResponseType<ContainerChargePageDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<ContainerChargePageDto>> Search(
        [FromQuery] ContainerChargeQuery query, CancellationToken cancellationToken)
    {
        var result = await _charges.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The filtered list, every page, with its total, as a workbook.</summary>
    [HttpGet("export")]
    [HasPermission(Permissions.Containers.ChargesView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] ContainerChargeQuery query, CancellationToken cancellationToken)
    {
        var result = await _charges.ExportAsync(query, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Containers.ChargesView)]
    [ProducesResponseType<ContainerChargeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ContainerChargeDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _charges.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>One draft per container, split by splitRule; answers the created drafts (201).</summary>
    [HttpPost]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType<IReadOnlyList<ContainerChargeGroupMemberDto>>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Create([FromBody] CreateContainerChargeRequest request, CancellationToken cancellationToken)
    {
        var result = await _charges.CreateAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Drafts only (409 NOT_EDITABLE otherwise).</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType<ContainerChargeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerChargeDto>> Update(
        int id, [FromBody] UpdateContainerChargeRequest request, CancellationToken cancellationToken)
    {
        var result = await _charges.UpdateAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Several drafts posted together, all or nothing: body { ids: [...] }.</summary>
    [HttpPost("post")]
    [HasPermission(Permissions.Containers.ChargesPost)]
    [ProducesResponseType<IReadOnlyList<ContainerChargeDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<ContainerChargeDto>>> PostMany(
        [FromBody] PostChargesRequest request, CancellationToken cancellationToken)
    {
        var result = await _charges.PostManyAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Containers.ChargesPost)]
    [ProducesResponseType<ContainerChargeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerChargeDto>> Post(
        int id, [FromBody] ChargeActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _charges.PostAsync(
            id, request ?? new ChargeActionRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Posted charges; when the container is offloaded the item costs are adjusted back.</summary>
    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Containers.ChargesCancel)]
    [ProducesResponseType<ContainerChargeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerChargeDto>> Cancel(
        int id, [FromBody] CancelRequest request, CancellationToken cancellationToken)
    {
        var result = await _charges.CancelAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The containers that can receive a copy: isSource = the charge's own, hasThisCharge = already in its group.</summary>
    [HttpGet("{id:int}/copy-candidates")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType<IReadOnlyList<ChargeCopyCandidateDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<ChargeCopyCandidateDto>>> CopyCandidates(
        int id, [FromQuery] ChargeCopyCandidateQuery query, CancellationToken cancellationToken)
    {
        var result = await _charges.GetCopyCandidatesAsync(id, query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The charge on other containers: one draft each in its group (201 with the created rows).
    /// post = true needs containers.charges.post. 409 DUPLICATE when a container already has it.
    /// </summary>
    [HttpPost("{id:int}/copy")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType<IReadOnlyList<CopiedContainerChargeDto>>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Copy(
        int id, [FromBody] CopyContainerChargeRequest request, CancellationToken cancellationToken)
    {
        var result = await _charges.CopyToContainersAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Drafts only.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _charges.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
