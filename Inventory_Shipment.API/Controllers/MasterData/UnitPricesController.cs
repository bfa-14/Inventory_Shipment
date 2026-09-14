using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// The price lookup a sales line makes when an item is picked by hand.
///
/// [Authorize] RATHER THAN A PRICE LIST PERMISSION: whoever may write an invoice line needs the price
/// it will carry, and that is a different set of people from those who maintain the lists. Reading
/// one price is not editing the list.
/// </summary>
[ApiController]
[Route("api/masterdata/unit-prices")]
[Produces("application/json")]
[Authorize]
public sealed class UnitPricesController : ControllerBase
{
    private readonly IPriceListService _priceLists;

    public UnitPricesController(IPriceListService priceLists)
    {
        _priceLists = priceLists;
    }

    /// <summary>
    /// The price of one unit in one list, the branch price winning over the All Branches price.
    /// Answers 200 with a null price when the list has none: the page shows that as a red line.
    /// </summary>
    [HttpGet("resolve")]
    [ProducesResponseType<UnitPriceResolutionDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<UnitPriceResolutionDto>> Resolve(
        [FromQuery] int itemUnitId, [FromQuery] int priceListId, [FromQuery] int? branchId,
        CancellationToken cancellationToken)
    {
        var result = await _priceLists.ResolveUnitPriceAsync(itemUnitId, priceListId, branchId, cancellationToken);
        return result.ToActionResult(this);
    }
}
