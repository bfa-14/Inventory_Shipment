using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// Landed cost adjustments: the freight bill that arrives three weeks after the goods.
///
/// POSTING ONE MOVES VALUE, NOT STOCK. The charges are spread over the invoice's lines and then
/// split — what is still on the shelf raises the inventory value and the item's average cost, what
/// has already been sold lands in the period's cost of sales. That is why it has the five verbs of
/// a document rather than being an edit to the invoice.
/// </summary>
[ApiController]
[Route("api/purchase/landed-cost-adjustments")]
[Produces("application/json")]
public sealed class LandedCostAdjustmentsController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly ILandedCostAdjustmentService _adjustments;

    public LandedCostAdjustmentsController(ILandedCostAdjustmentService adjustments)
    {
        _adjustments = adjustments;
    }

    [HttpGet]
    [HasPermission(Permissions.Purchase.LandedCostsView)]
    [ProducesResponseType<PagedResult<LandedCostAdjustmentListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<LandedCostAdjustmentListDto>>> Search(
        [FromQuery] LandedCostAdjustmentQuery query, CancellationToken cancellationToken)
    {
        var result = await _adjustments.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Purchase.LandedCostsView)]
    [ProducesResponseType<LandedCostAdjustmentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<LandedCostAdjustmentDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _adjustments.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost]
    [HasPermission(Permissions.Purchase.LandedCostsCreate)]
    [ProducesResponseType<LandedCostAdjustmentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LandedCostAdjustmentDto>> Create(
        [FromBody] SaveLandedCostAdjustmentRequest request, CancellationToken cancellationToken)
    {
        var result = await _adjustments.SaveDraftAsync(
            null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Purchase.LandedCostsCreate)]
    [ProducesResponseType<LandedCostAdjustmentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LandedCostAdjustmentDto>> Update(
        int id, [FromBody] SaveLandedCostAdjustmentRequest request, CancellationToken cancellationToken)
    {
        var result = await _adjustments.SaveDraftAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Purchase.LandedCostsPost)]
    [ProducesResponseType<LandedCostAdjustmentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LandedCostAdjustmentDto>> Post(
        int id, [FromBody] PostLandedCostAdjustmentRequest? request, CancellationToken cancellationToken)
    {
        var result = await _adjustments.PostAsync(
            id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Purchase.LandedCostsCancel)]
    [ProducesResponseType<LandedCostAdjustmentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<LandedCostAdjustmentDto>> Cancel(
        int id, [FromBody] CancelLandedCostAdjustmentRequest request, CancellationToken cancellationToken)
    {
        var result = await _adjustments.CancelAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Purchase.LandedCostsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _adjustments.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    [HttpGet("{id:int}/export")]
    [HasPermission(Permissions.Purchase.LandedCostsView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _adjustments.ExportAsync(id, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }
}
