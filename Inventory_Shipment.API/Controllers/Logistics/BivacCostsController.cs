using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Script 97: a BIVAC item's cost per port (Item Definition) and the BIVAC items a charge on the chosen containers
/// may name, with what each would cost there.
/// </summary>
[ApiController]
[Produces("application/json")]
public sealed class BivacCostsController : ControllerBase
{
    private readonly IBivacCostService _service;

    public BivacCostsController(IBivacCostService service)
    {
        _service = service;
    }

    /// <summary>The BIVAC item's cost at each port that has one.</summary>
    [HttpGet("api/inventory/items/{id:int}/bivac-port-costs")]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [ProducesResponseType<IReadOnlyList<ItemBivacPortCostDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ItemBivacPortCostDto>>> GetPortCosts(int id, CancellationToken cancellationToken)
        => (await _service.GetPortCostsAsync(id, cancellationToken)).ToActionResult(this);

    /// <summary>Replaces the item's costs per port: a port left out has no cost.</summary>
    [HttpPut("api/inventory/items/{id:int}/bivac-port-costs")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType<IReadOnlyList<ItemBivacPortCostDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<ItemBivacPortCostDto>>> SetPortCosts(
        int id, [FromBody] SetItemBivacPortCostsRequest request, CancellationToken cancellationToken)
        => (await _service.SetPortCostsAsync(id, request, User.GetUserId(), cancellationToken)).ToActionResult(this);

    /// <summary>The BIVAC items a BIVAC charge on these containers may name, and each container's port.</summary>
    [HttpPost("api/logistics/container-charges/bivac-options")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType<BivacChargeOptionsDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<BivacChargeOptionsDto>> GetChargeOptions(
        [FromBody] BivacChargeOptionsRequest request, CancellationToken cancellationToken)
        => (await _service.GetChargeOptionsAsync(request.ContainerIds ?? [], cancellationToken)).ToActionResult(this);
}
