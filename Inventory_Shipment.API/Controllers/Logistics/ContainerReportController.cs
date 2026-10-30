using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Reports › Container Report (script 95): every container line and every order line still to load, with its order,
/// invoices, payments, journey, charges and cost, by stage.
///
/// NOT PAGED. The page holds the whole report: it groups the rows by stage and totals each group, and a total over one
/// page of rows would be a wrong total.
/// </summary>
[ApiController]
[Route("api/logistics/container-report")]
[Produces("application/json")]
public sealed class ContainerReportController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IContainerReportService _reports;

    public ContainerReportController(IContainerReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Containers.ReportView)]
    [ProducesResponseType<ContainerReportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<ContainerReportResult>> Report(
        [FromQuery] ContainerReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ReportAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Containers.ReportView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] ContainerReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportAsync(query, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }
}
