using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>Company branches / sites (master data referenced by warehouses, stock and transactions).</summary>
[ApiController]
[Route("api/masterdata/branches")]
[Produces("application/json")]
public sealed class BranchesController : ControllerBase
{
    private readonly IBranchService _branchService;

    public BranchesController(IBranchService branchService)
    {
        _branchService = branchService;
    }

    /// <summary>Paged, filtered and sorted list of branches.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.BranchesView)]
    [ProducesResponseType<PagedResult<BranchDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<BranchDto>>> Search(
        [FromQuery] BranchQuery query, CancellationToken cancellationToken)
    {
        var result = await _branchService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Branches for a Branch / Site dropdown. Any signed-in user may read it: every master-data form with a
    /// Branch / Site picker needs it, not only the users who administer branches.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<BranchLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<BranchLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _branchService.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The branch currently designated as the Main Branch.</summary>
    [HttpGet("main")]
    [HasPermission(Permissions.MasterData.BranchesView)]
    [ProducesResponseType<BranchDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<BranchDto>> GetMain(CancellationToken cancellationToken)
    {
        var result = await _branchService.GetMainAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.BranchesView)]
    [ProducesResponseType<BranchDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<BranchDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _branchService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a branch. Marking it as the Main Branch while another one holds the flag fails with
    /// code MAIN_BRANCH_EXISTS; resend with replaceMainBranch = true once the user confirms.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.BranchesCreate)]
    [ProducesResponseType<BranchDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<BranchDto>> Create(
        [FromBody] SaveBranchRequest request, CancellationToken cancellationToken)
    {
        var result = await _branchService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates a branch. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.BranchesEdit)]
    [ProducesResponseType<BranchDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<BranchDto>> Update(
        int id, [FromBody] SaveBranchRequest request, CancellationToken cancellationToken)
    {
        var result = await _branchService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a branch. The Main Branch cannot be deactivated.</summary>
    [HttpPatch("{id:int}/status")]
    [HasPermission(Permissions.MasterData.BranchesEdit)]
    [ProducesResponseType<BranchDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<BranchDto>> SetStatus(
        int id, [FromBody] SetBranchStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _branchService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a branch that no other record references. The Main Branch cannot be deleted.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.BranchesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _branchService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
