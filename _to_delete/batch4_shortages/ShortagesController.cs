using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>The shortage report: what is below its minimum, and the purchase orders that fix it.</summary>
[ApiController]
[Route("api/inventory/shortages")]
[Produces("application/json")]
public sealed class ShortagesController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IShortageService _shortages;

    public ShortagesController(IShortageService shortages)
    {
        _shortages = shortages;
    }

    /// <summary>Not paged: the page filters, sorts and sums the rows itself.</summary>
    [HttpGet]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [ProducesResponseType<IReadOnlyList<ShortageRowDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ShortageRowDto>>> Report(
        [FromQuery] ShortageQuery query, CancellationToken cancellationToken)
    {
        var result = await _shortages.ReportAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] ShortageQuery query, CancellationToken cancellationToken)
    {
        var result = await _shortages.ExportAsync(query, cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>One draft purchase order per supplier and warehouse. Needs purchase.orders.create, checked here and in the service.</summary>
    [HttpPost("create-orders")]
    [HasPermission(Permissions.Purchase.OrdersCreate)]
    [ProducesResponseType<CreatePurchaseOrdersResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<CreatePurchaseOrdersResult>> CreateOrders(
        [FromBody] CreatePurchaseOrdersFromShortagesRequest request, CancellationToken cancellationToken)
    {
        var result = await _shortages.CreateOrdersAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
