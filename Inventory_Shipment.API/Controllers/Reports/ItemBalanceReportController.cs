using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Reports;

/// <summary>
/// Reports › Item Balance Report (script 103): each item's opening, movements and closing per warehouse over a period,
/// at the company's average cost, in the base currency or translated into another one.
///
/// NOT PAGED: the totals and the integrity check are over every row. Each run (screen, print, Excel) is logged with its
/// filters and its user. The amounts need View item costs; the warehouses are the reader's own.
/// </summary>
[ApiController]
[Route("api/reports/item-balance")]
[Produces("application/json")]
public sealed class ItemBalanceReportController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IItemBalanceReportService _reports;

    public ItemBalanceReportController(IItemBalanceReportService reports)
    {
        _reports = reports;
    }

    /// <summary>The report. <c>print=true</c> when the print page asks, so the run log says so.</summary>
    [HttpGet]
    [HasPermission(Permissions.Reports.ItemBalanceView)]
    [ProducesResponseType<ItemBalanceReportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ItemBalanceReportResult>> Report(
        [FromQuery] ItemBalanceReportQuery query, [FromQuery] bool print, CancellationToken cancellationToken)
    {
        var result = await _reports.ReportAsync(query, print ? "Print" : "Screen", User.GetUserId(), User.Identity?.Name ?? string.Empty,
            User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Reports.ItemBalanceView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] ItemBalanceReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportAsync(query, User.GetUserId(), User.Identity?.Name ?? string.Empty,
            User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>The warehouses the filter offers: the reader's own.</summary>
    [HttpGet("warehouses")]
    [HasPermission(Permissions.Reports.ItemBalanceView)]
    [ProducesResponseType<IReadOnlyList<ItemBalanceWarehouseDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ItemBalanceWarehouseDto>>> Warehouses(CancellationToken cancellationToken)
    {
        var result = await _reports.WarehousesAsync(User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The movements behind one cell (an item in a warehouse, one kind of movement or all of them).</summary>
    [HttpGet("movements")]
    [HasPermission(Permissions.Reports.ItemBalanceView)]
    [ProducesResponseType<ItemBalanceMovementsResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<ItemBalanceMovementsResult>> Movements(
        [FromQuery] ItemBalanceMovementsQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.MovementsAsync(query, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
