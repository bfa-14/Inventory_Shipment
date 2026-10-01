using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Sales;

/// <summary>
/// The log of out-of-stock sales: every time a user confirmed selling more than a warehouse held. Newest
/// first. Read-only - the rows are written by the invoice post, in the same transaction as the sale.
/// </summary>
[ApiController]
[Route("api/sales/out-of-stock-audit")]
[Produces("application/json")]
public sealed class OutOfStockAuditController : ControllerBase
{
    private readonly IOutOfStockAuditService _audit;

    public OutOfStockAuditController(IOutOfStockAuditService audit)
    {
        _audit = audit;
    }

    [HttpGet]
    [HasPermission(Permissions.Sales.OutOfStockAuditView)]
    [ProducesResponseType<PagedResult<OutOfStockAuditDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<OutOfStockAuditDto>>> Search(
        [FromQuery] OutOfStockAuditQuery query, CancellationToken cancellationToken)
    {
        var result = await _audit.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }
}
