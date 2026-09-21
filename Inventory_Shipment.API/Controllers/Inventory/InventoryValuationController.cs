using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// What the stock is worth: on hand × the item's moving average cost.
///
/// GUARDED BY inventory.items.view, because that is what it is — the item list with its money
/// shown. Without a warehouse it answers for the company; with one, for that warehouse's shelves
/// at the same company-wide average, which is what a sale out of it is costed at.
/// </summary>
[ApiController]
[Route("api/inventory/valuation")]
[Produces("application/json")]
public sealed class InventoryValuationController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly ICostingReportService _reports;

    public InventoryValuationController(ICostingReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [ProducesResponseType<InventoryValuationResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<InventoryValuationResult>> Valuation(
        [FromQuery] int? warehouseId, CancellationToken cancellationToken)
    {
        var result = await _reports.ValuationAsync(warehouseId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] int? warehouseId, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportValuationAsync(warehouseId, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }
}
