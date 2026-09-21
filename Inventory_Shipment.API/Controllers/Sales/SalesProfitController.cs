using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Sales;

/// <summary>
/// What selling the goods earned: net sales less the cost frozen on each line when it was posted.
///
/// NOT PAGED. One row per group and the page sums them for its cards; a total over one page of
/// groups would be a wrong total, and the groups are few by construction.
/// </summary>
[ApiController]
[Route("api/sales/profit")]
[Produces("application/json")]
public sealed class SalesProfitController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly ICostingReportService _reports;

    public SalesProfitController(ICostingReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Sales.ProfitView)]
    [ProducesResponseType<IReadOnlyList<SalesProfitRowDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<SalesProfitRowDto>>> Report(
        [FromQuery] SalesProfitQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.SalesProfitAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("export")]
    [HasPermission(Permissions.Sales.ProfitView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export([FromQuery] SalesProfitQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ExportSalesProfitAsync(query, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }
}
