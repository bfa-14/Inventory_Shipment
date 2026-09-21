using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// Purchase charge types (US-MD-008): freight, customs, clearing — what they are called, how each
/// is spread over the goods, and whether it reaches the item cost at all.
///
/// SETUP, NOT BUYING. One permission guards the writes, and it sits in Configuration rather than
/// Purchase: a charge type is a rule the company agrees once, and the person who enters a freight
/// bill is not the person who decides that freight is allocated by weight. The LOOKUP is open to
/// any signed-in user, because every charge line on every invoice has to name one.
/// </summary>
[ApiController]
[Route("api/purchase/charge-types")]
[Produces("application/json")]
public sealed class ChargeTypesController : ControllerBase
{
    private readonly IChargeTypeService _chargeTypes;

    public ChargeTypesController(IChargeTypeService chargeTypes)
    {
        _chargeTypes = chargeTypes;
    }

    [HttpGet]
    [HasPermission(Permissions.Configuration.ChargeTypesManage)]
    [ProducesResponseType<PagedResult<ChargeTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ChargeTypeDto>>> Search(
        [FromQuery] ChargeTypeQuery query, CancellationToken cancellationToken)
    {
        var result = await _chargeTypes.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>For the charge lines of an invoice or an adjustment. Any signed-in user.</summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<ChargeTypeLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ChargeTypeLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _chargeTypes.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Configuration.ChargeTypesManage)]
    [ProducesResponseType<ChargeTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ChargeTypeDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _chargeTypes.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost]
    [HasPermission(Permissions.Configuration.ChargeTypesManage)]
    [ProducesResponseType<ChargeTypeDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ChargeTypeDto>> Create(
        [FromBody] SaveChargeTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _chargeTypes.SaveAsync(null, request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Configuration.ChargeTypesManage)]
    [ProducesResponseType<ChargeTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ChargeTypeDto>> Update(
        int id, [FromBody] SaveChargeTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _chargeTypes.SaveAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps the history a used type carries; deleting is only for one nothing has used.</summary>
    [HttpPatch("{id:int}/active")]
    [HasPermission(Permissions.Configuration.ChargeTypesManage)]
    [ProducesResponseType<ChargeTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ChargeTypeDto>> SetActive(
        int id, [FromBody] SetChargeTypeActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _chargeTypes.SetActiveAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Configuration.ChargeTypesManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _chargeTypes.DeleteAsync(id, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
