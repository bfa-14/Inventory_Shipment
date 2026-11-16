using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Reports;

/// <summary>
/// Reports › Goods on Order (script 109): everything ordered and not received yet, per item and per stage of the journey
/// (the columns are the stages the containers are at now). NOT PAGED: the totals are over every row.
/// </summary>
[ApiController]
[Route("api/reports/goods-on-order")]
[Produces("application/json")]
public sealed class GoodsOnOrderReportController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IGoodsOnOrderReportService _reports;

    public GoodsOnOrderReportController(IGoodsOnOrderReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Reports.GoodsOnOrderView)]
    [ProducesResponseType<GoodsOnOrderReportResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<GoodsOnOrderReportResult>> Report(
        [FromQuery] GoodsOnOrderReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ReportAsync(query, User.Identity?.Name ?? string.Empty, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Reports.GoodsOnOrderView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] GoodsOnOrderReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportAsync(query, User.Identity?.Name ?? string.Empty, User.GetPermissions(), cancellationToken);
        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }
}
