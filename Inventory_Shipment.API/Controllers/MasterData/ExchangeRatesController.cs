using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// Exchange rates. A rate means: 1 unit of the base currency = Rate units of the quoted currency, on a date.
/// There is one rate per currency + rate type + date, and a rate stays in force until a newer date exists.
/// </summary>
[ApiController]
[Route("api/masterdata/exchange-rates")]
[Produces("application/json")]
public sealed class ExchangeRatesController : ControllerBase
{
    private readonly IExchangeRateService _exchangeRateService;

    public ExchangeRatesController(IExchangeRateService exchangeRateService)
    {
        _exchangeRateService = exchangeRateService;
    }

    /// <summary>Paged, filtered and sorted list of exchange rates (newest date first by default).</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.ExchangeRatesView)]
    [ProducesResponseType<PagedResult<ExchangeRateDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ExchangeRateDto>>> Search(
        [FromQuery] ExchangeRateQuery query, CancellationToken cancellationToken)
    {
        var result = await _exchangeRateService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The rate in force per rate type for one currency (0 to 3 rows: Official, Non-official, Market).
    /// Any signed-in user may read it: screens that convert an amount need the rate, not only the users
    /// who maintain rates. Omit asOf for today (UTC).
    /// </summary>
    [HttpGet("latest")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<ExchangeRateDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ExchangeRateDto>>> Latest(
        [FromQuery] int currencyId, [FromQuery] DateOnly? asOf = null, CancellationToken cancellationToken = default)
    {
        var result = await _exchangeRateService.LatestAsync(currencyId, asOf, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.ExchangeRatesView)]
    [ProducesResponseType<ExchangeRateDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ExchangeRateDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _exchangeRateService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Enters a rate. The date cannot be in the future, the currency must be active, and it must not be the
    /// base currency. A second rate for the same currency, type and date fails with code DUPLICATE_RATE.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.ExchangeRatesCreate)]
    [ProducesResponseType<ExchangeRateDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ExchangeRateDto>> Create(
        [FromBody] SaveExchangeRateRequest request, CancellationToken cancellationToken)
    {
        var result = await _exchangeRateService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Corrects a rate. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.ExchangeRatesEdit)]
    [ProducesResponseType<ExchangeRateDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ExchangeRateDto>> Update(
        int id, [FromBody] SaveExchangeRateRequest request, CancellationToken cancellationToken)
    {
        var result = await _exchangeRateService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Removes a wrongly entered rate. Transactions snapshot the rate they used, so deleting one here
    /// never rewrites history.
    /// </summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.ExchangeRatesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _exchangeRateService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
