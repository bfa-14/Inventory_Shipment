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
/// Currencies. Exactly one active currency is the Base Currency: amounts are stored and reported in it,
/// and it never has exchange rates because its rate is 1 by definition.
/// </summary>
[ApiController]
[Route("api/masterdata/currencies")]
[Produces("application/json")]
public sealed class CurrenciesController : ControllerBase
{
    private readonly ICurrencyService _currencyService;

    public CurrenciesController(ICurrencyService currencyService)
    {
        _currencyService = currencyService;
    }

    /// <summary>Paged, filtered and sorted list of currencies.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.CurrenciesView)]
    [ProducesResponseType<PagedResult<CurrencyDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<CurrencyDto>>> Search(
        [FromQuery] CurrencyQuery query, CancellationToken cancellationToken)
    {
        var result = await _currencyService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Currencies for a dropdown, base currency first. Any signed-in user may read it: forms all over the
    /// application offer a currency to pick, not only the users who administer currencies.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<CurrencyLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<CurrencyLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null,
        CancellationToken cancellationToken = default)
    {
        var result = await _currencyService.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The currency currently designated as the Base Currency. Any signed-in user may read it: every screen
    /// that shows an amount needs to know which currency the figures are expressed in.
    /// </summary>
    [HttpGet("base")]
    [Authorize]
    [ProducesResponseType<CurrencyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<CurrencyDto>> GetBase(CancellationToken cancellationToken)
    {
        var result = await _currencyService.GetBaseAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.CurrenciesView)]
    [ProducesResponseType<CurrencyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<CurrencyDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _currencyService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a currency. The code is stored upper-case. Marking it as the Base Currency while another one
    /// holds the flag fails with code BASE_CURRENCY_EXISTS; resend with replaceBaseCurrency = true once the
    /// user confirms.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.CurrenciesCreate)]
    [ProducesResponseType<CurrencyDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CurrencyDto>> Create(
        [FromBody] SaveCurrencyRequest request, CancellationToken cancellationToken)
    {
        var result = await _currencyService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates a currency. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.CurrenciesEdit)]
    [ProducesResponseType<CurrencyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CurrencyDto>> Update(
        int id, [FromBody] SaveCurrencyRequest request, CancellationToken cancellationToken)
    {
        var result = await _currencyService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a currency. The Base Currency cannot be deactivated.</summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.MasterData.CurrenciesEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> SetStatus(
        int id, [FromBody] SetCurrencyStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _currencyService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Deletes a currency that no other record references. The Base Currency cannot be deleted.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.CurrenciesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _currencyService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
