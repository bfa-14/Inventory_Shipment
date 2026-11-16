using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Reports;

/// <summary>
/// Reports › Dispatched Items (script 106): the items dispatched in a period (from India by default), as the item balance
/// and as the items / containers. NOT PAGED: the totals are over every row. The oil deduction needs View Container
/// Charges, the payment columns View Supplier Payments.
/// </summary>
[ApiController]
[Route("api/reports/dispatched-items")]
[Produces("application/json")]
public sealed class DispatchedItemsReportController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IDispatchedItemsReportService _reports;

    public DispatchedItemsReportController(IDispatchedItemsReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Reports.DispatchedItemsView)]
    [ProducesResponseType<DispatchedItemsReportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<DispatchedItemsReportResult>> Report(
        [FromQuery] DispatchedItemsReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ReportAsync(query, User.Identity?.Name ?? string.Empty, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Reports.DispatchedItemsView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] DispatchedItemsReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportAsync(query, User.Identity?.Name ?? string.Empty, User.GetPermissions(), cancellationToken);
        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }
}
