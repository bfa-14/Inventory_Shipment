using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>Units of measure items are packed in (PC, Box, Pallet, Container...).</summary>
[ApiController]
[Route("api/masterdata/unit-types")]
[Produces("application/json")]
public sealed class UnitTypesController : ControllerBase
{
    private readonly IUnitTypeService _unitTypeService;

    public UnitTypesController(IUnitTypeService unitTypeService)
    {
        _unitTypeService = unitTypeService;
    }

    /// <summary>Paged, filtered and sorted list of unit types.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.UnitTypesView)]
    [ProducesResponseType<PagedResult<UnitTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<UnitTypeDto>>> Search(
        [FromQuery] UnitTypeQuery query, CancellationToken cancellationToken)
    {
        var result = await _unitTypeService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Unit types for a dropdown. Any signed-in user may read it: the item form needs it, not only
    /// the users who administer unit types.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<UnitTypeLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<UnitTypeLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _unitTypeService.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.UnitTypesView)]
    [ProducesResponseType<UnitTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<UnitTypeDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _unitTypeService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Creates a unit type. A name already in use fails with code DUPLICATE_NAME.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.UnitTypesCreate)]
    [ProducesResponseType<UnitTypeDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<UnitTypeDto>> Create(
        [FromBody] SaveUnitTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _unitTypeService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates a unit type. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.UnitTypesEdit)]
    [ProducesResponseType<UnitTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<UnitTypeDto>> Update(
        int id, [FromBody] SaveUnitTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _unitTypeService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a unit type.</summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.MasterData.UnitTypesEdit)]
    [ProducesResponseType<UnitTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<UnitTypeDto>> SetStatus(
        int id, [FromBody] SetUnitTypeStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _unitTypeService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a unit type that no item unit uses.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.UnitTypesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _unitTypeService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
