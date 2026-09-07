using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>Selling price lists (master data; each list prices in a single currency).</summary>
[ApiController]
[Route("api/masterdata/price-lists")]
[Produces("application/json")]
public sealed class PriceListsController : ControllerBase
{
    private readonly IPriceListService _priceListService;

    public PriceListsController(IPriceListService priceListService)
    {
        _priceListService = priceListService;
    }

    /// <summary>Paged, filtered and sorted list of price lists.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.PriceListsView)]
    [ProducesResponseType<PagedResult<PriceListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<PriceListDto>>> Search(
        [FromQuery] PriceListQuery query, CancellationToken cancellationToken)
    {
        var result = await _priceListService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Price lists for a Price List dropdown. Any signed-in user may read it: every form with a
    /// Price List picker needs it, not only the users who administer price lists.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<PriceListLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<PriceListLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _priceListService.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.PriceListsView)]
    [ProducesResponseType<PriceListDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PriceListDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _priceListService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a price list. A code or name already in use fails with code DUPLICATE_CODE; a missing or
    /// inactive currency fails with CURRENCY_INACTIVE.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.PriceListsCreate)]
    [ProducesResponseType<PriceListDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PriceListDto>> Create(
        [FromBody] SavePriceListRequest request, CancellationToken cancellationToken)
    {
        var result = await _priceListService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Updates a price list. Send the rowVersion read with it to detect concurrent edits. The currency
    /// can no longer be changed once the list holds prices (code CURRENCY_LOCKED).
    /// </summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.PriceListsEdit)]
    [ProducesResponseType<PriceListDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PriceListDto>> Update(
        int id, [FromBody] SavePriceListRequest request, CancellationToken cancellationToken)
    {
        var result = await _priceListService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a price list.</summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.MasterData.PriceListsEdit)]
    [ProducesResponseType<PriceListDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PriceListDto>> SetStatus(
        int id, [FromBody] SetPriceListStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _priceListService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a price list that holds no prices and that no other record references.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.PriceListsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _priceListService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
