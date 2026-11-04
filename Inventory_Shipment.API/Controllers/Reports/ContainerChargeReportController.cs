using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Reports;

/// <summary>
/// Reports › Container Charges (script 105): the containers offloaded or dispatched in a period with, per charge type
/// asked, the charge entered or missing, its amount and its payments. NOT PAGED: the totals are over every row. The
/// payment columns need View Supplier Payments.
/// </summary>
[ApiController]
[Route("api/reports/container-charges")]
[Produces("application/json")]
public sealed class ContainerChargeReportController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IContainerChargeReportService _reports;

    public ContainerChargeReportController(IContainerChargeReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Reports.ContainerChargesView)]
    [ProducesResponseType<ContainerChargeReportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<ContainerChargeReportResult>> Report(
        [FromQuery] ContainerChargeReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ReportAsync(query, User.Identity?.Name ?? string.Empty, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Reports.ContainerChargesView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] ContainerChargeReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportAsync(query, User.Identity?.Name ?? string.Empty, User.GetPermissions(), cancellationToken);
        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>What the filters offer: every charge type and the suppliers of containers.</summary>
    [HttpGet("options")]
    [HasPermission(Permissions.Reports.ContainerChargesView)]
    [ProducesResponseType<ContainerChargeReportOptions>(StatusCodes.Status200OK)]
    public async Task<ActionResult<ContainerChargeReportOptions>> Options(CancellationToken cancellationToken)
    {
        var result = await _reports.OptionsAsync(User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
