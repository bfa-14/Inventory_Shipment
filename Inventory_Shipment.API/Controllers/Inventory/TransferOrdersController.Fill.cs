using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.Security;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// (91) FILL TO MAX AND ADD ITEMS BELOW MIN on a saved draft (Create Transfer Orders, FB decision 20). The rule is the
/// server's: the preview writes nothing; the apply sends the ORDER's row version, computes the plan again and answers the
/// order re-read. The refusals are fn_TransferOrder_Blocks' sentences with the codes of every transfer action (62005 a
/// released order, 62009 no lines or no levels at To, 62004 changed by another user, 62006 an order that does not exist).
/// </summary>
public sealed partial class TransferOrdersController
{
    /// <summary>Body { addItems: [] } = Fill the order's lines; { addItems: [{ itemId, itemUnitId }] } = Add those items. Nothing is written.</summary>
    [HttpPost("{id:int}/fill-to-max/preview")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferFillResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferFillResult>> FillToMaxPreview(
        int id, [FromBody] TransferFillRequest? request, CancellationToken cancellationToken)
    {
        var result = await _transfers.FillToMaxPreviewAsync(id, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Body { rowVersion, addItems }: the plan computed again and written (the item's first line set, or new lines added).</summary>
    [HttpPost("{id:int}/fill-to-max")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferFillResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferFillResult>> FillToMax(
        int id, [FromBody] TransferFillRequest? request, CancellationToken cancellationToken)
    {
        var result = await _transfers.FillToMaxAsync(id, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// "Add items below Min…": every item with a level at the order's To (search, itemFamilyId, brandId, onlyBelowMin
    /// true by default), with where To stands, what From has available and the server's proposal per unit.
    /// </summary>
    [HttpGet("{id:int}/below-min")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferBelowMinResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferBelowMinResult>> BelowMin(
        int id, [FromQuery] TransferBelowMinQuery query, CancellationToken cancellationToken)
    {
        var result = await _transfers.BelowMinAsync(id, query, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
