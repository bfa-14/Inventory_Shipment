using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// A currency's rate on a day, for the purchase document page. Any signed-in user: the rate is
/// public knowledge inside the company, and the page needs it before it knows which document
/// kind — and therefore which permission — it is making.
/// </summary>
[ApiController]
[Authorize]
[Route("api/purchase/rate")]
[Produces("application/json")]
public sealed class PurchaseRatesController : ControllerBase
{
    private readonly IPurchaseDocumentService _documents;

    public PurchaseRatesController(IPurchaseDocumentService documents)
    {
        _documents = documents;
    }

    [HttpGet]
    [ProducesResponseType<PurchaseRateResolutionDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PurchaseRateResolutionDto>> GetRate(
        [FromQuery] int currencyId, [FromQuery] byte rateType = RateTypes.Official,
        [FromQuery] DateOnly? date = null, CancellationToken cancellationToken = default)
    {
        var result = await _documents.ResolveRateAsync(currencyId, rateType, date, cancellationToken);
        return result.ToActionResult(this);
    }
}
