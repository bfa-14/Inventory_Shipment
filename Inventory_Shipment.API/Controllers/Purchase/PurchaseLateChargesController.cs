using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// Late charges of a POSTED local purchase invoice — the freight bill that arrives after the goods —
/// entered from the invoice itself.
///
/// THEY ARE LANDED COST ADJUSTMENTS. Each charge goes into the invoice's open draft adjustment and
/// posting it moves the value, exactly as on the Landed Cost Adjustments page, with the same
/// permissions. An imported invoice (from containers) takes its late charges on its containers, and
/// a draft invoice on its own charges: both answer 409.
/// </summary>
[ApiController]
[Route("api/purchase/documents/{id:int}/late-charges")]
[Produces("application/json")]
public sealed class PurchaseLateChargesController : ControllerBase
{
    private readonly ILateChargeService _lateCharges;

    public PurchaseLateChargesController(ILateChargeService lateCharges)
    {
        _lateCharges = lateCharges;
    }

    /// <summary>The open draft adjustment, and the charges of every adjustment of the invoice, the newest first.</summary>
    [HttpGet]
    [HasPermission(Permissions.Purchase.LandedCostsView)]
    [ProducesResponseType<LateChargesDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LateChargesDto>> Get(int id, CancellationToken cancellationToken)
    {
        var result = await _lateCharges.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Adds a charge to the open draft adjustment, created (and numbered) when there is none.</summary>
    [HttpPost]
    [HasPermission(Permissions.Purchase.LandedCostsCreate)]
    [ProducesResponseType<LateChargesDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LateChargesDto>> Add(
        int id, [FromBody] SaveLateChargeRequest request, CancellationToken cancellationToken)
    {
        var result = await _lateCharges.AddAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPut("{chargeId:int}")]
    [HasPermission(Permissions.Purchase.LandedCostsCreate)]
    [ProducesResponseType<LateChargesDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LateChargesDto>> Update(
        int id, int chargeId, [FromBody] SaveLateChargeRequest request, CancellationToken cancellationToken)
    {
        var result = await _lateCharges.UpdateAsync(
            id, chargeId, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Removes a draft late charge; the last one takes its empty draft adjustment with it.</summary>
    [HttpDelete("{chargeId:int}")]
    [HasPermission(Permissions.Purchase.LandedCostsCreate)]
    [ProducesResponseType<LateChargesDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LateChargesDto>> Delete(int id, int chargeId, CancellationToken cancellationToken)
    {
        var result = await _lateCharges.DeleteAsync(id, chargeId, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Posts the open draft adjustment: each line's landed cost before and after, and where the value went.</summary>
    [HttpPost("post")]
    [HasPermission(Permissions.Purchase.LandedCostsPost)]
    [ProducesResponseType<LateChargesPostedDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LateChargesPostedDto>> Post(
        int id, [FromBody] PostLateChargesRequest? request, CancellationToken cancellationToken)
    {
        var result = await _lateCharges.PostAsync(
            id, request ?? new PostLateChargesRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Cancels a posted adjustment of the invoice: its value comes back out of stock and cost of sales.</summary>
    [HttpPost("{adjustmentId:int}/cancel")]
    [HasPermission(Permissions.Purchase.LandedCostsCancel)]
    [ProducesResponseType<LateChargesDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LateChargesDto>> Cancel(
        int id, int adjustmentId, [FromBody] CancelLandedCostAdjustmentRequest request, CancellationToken cancellationToken)
    {
        var result = await _lateCharges.CancelAsync(
            id, adjustmentId, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }
}
