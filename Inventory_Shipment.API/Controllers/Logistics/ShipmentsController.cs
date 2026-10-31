using System.Text.Json;
using System.Text.Json.Serialization;
using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

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
    /// <summary>The application's JSON options with nulls left out: built once, from the first request's options.</summary>
    private static JsonSerializerOptions? _boardJson;

    private readonly IContainerService _containers;
    private readonly IOptions<JsonOptions> _json;

    public ShipmentsController(IContainerService containers, IOptions<JsonOptions> json)
    {
        _containers = containers;
        _json = json;
    }

    /// <summary>
    /// THE BOARD LEAVES OUT ITS EMPTY FIELDS, for this endpoint only: 5,000 open containers were 11.9 MB of JSON, 45% of it
    /// nulls of the leg, the planned leg and the goods receipt a card does not have (3.6 MB now, with the card trimmed to
    /// what the page reads). Everything else is the application's own options (camelCase, enums as text, *Utc with its
    /// "Z"); the page reads an absent field as null.
    /// </summary>
    private JsonSerializerOptions BoardJson => _boardJson ??= new JsonSerializerOptions(_json.Value.JsonSerializerOptions)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>
    /// The board: { columns: [{ phase, title, phaseOrder, count, pieces }], containers: [card] } - every container on it
    /// (no paging), in the order of the board (column, group, ref), each with its column (phase), its group (groupKey,
    /// groupLabel, groupOrder), its card and its next step. Filters: search (ref, container no., B/L, vessel or truck,
    /// purchase order number), supplierId, purchaseOrderId, branchId, placeId (where it stands, or the From / To of its leg),
    /// lateOnly, withPlannedLeg, showReceived. 400 VALIDATION for an id of 0 or less. A card's empty fields are left out.
    /// </summary>
    [HttpGet("board")]
    [HasPermission(Permissions.Containers.ShipmentsView)]
    [ProducesResponseType<ShipmentBoardDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<ShipmentBoardDto>> Board([FromQuery] ShipmentBoardQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.GetShipmentBoardAsync(query, User.GetPermissions(), cancellationToken);
        return result.IsSuccess ? new JsonResult(result.Value, BoardJson) : this.ToProblem(result);
    }
}
