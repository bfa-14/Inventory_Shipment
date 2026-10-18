using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// (82) Logistics › Shipments: every container on its way, in one column by stage - At supplier, At sea, At port, On the
/// road, At border / customs, Delivered, to receive (and with showReceived the ones received in the last 30 days). The
/// column is the database's (logistics.fn_Container_BoardPhase), from the same movements as each container's next step;
/// moving a container is the Next step dialogs' (POST api/logistics/containers/next-step), never this board's.
/// </summary>
[ApiController]
[Route("api/logistics/shipments")]
[Produces("application/json")]
public sealed class ShipmentsController : ControllerBase
{
    private readonly IContainerService _containers;

    public ShipmentsController(IContainerService containers)
    {
        _containers = containers;
    }

    /// <summary>
    /// The board: { columns: [{ phase, title, phaseOrder, count, pieces }], containers: [card] } - every container on it
    /// (no paging), in the order of the board (column, group, ref), each with its column (phase), its group (groupKey,
    /// groupLabel, groupOrder), its card and its next step. Filters: search (ref, container no., B/L, vessel or truck,
    /// purchase order number), supplierId, purchaseOrderId, branchId, placeId (where it stands, or the From / To of its leg),
    /// lateOnly, withPlannedLeg, showReceived. 400 VALIDATION for an id of 0 or less.
    /// </summary>
    [HttpGet("board")]
    [HasPermission(Permissions.Containers.ShipmentsView)]
    [ProducesResponseType<ShipmentBoardDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<ShipmentBoardDto>> Board([FromQuery] ShipmentBoardQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.GetShipmentBoardAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
