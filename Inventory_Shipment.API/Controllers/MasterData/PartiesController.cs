using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Enums;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// Parties - the one master behind suppliers, clients, salesmen and employees. A party carries four
/// independent type flags, so the same company can be both a supplier and a client without being
/// entered twice.
/// </summary>
[ApiController]
[Route("api/masterdata/parties")]
[Produces("application/json")]
public sealed class PartiesController : ControllerBase
{
    private readonly IPartyService _partyService;

    public PartiesController(IPartyService partyService)
    {
        _partyService = partyService;
    }

    /// <summary>Paged, filtered and sorted list of parties.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.PartiesView)]
    [ProducesResponseType<PagedResult<PartyDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<PartyDto>>> Search(
        [FromQuery] PartyQuery query, CancellationToken cancellationToken)
    {
        var result = await _partyService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Parties for a typed dropdown (suppliers on a purchase order, clients on an invoice...).
    /// Any signed-in user may read it: every form with a party picker needs it, not only the users
    /// who administer parties.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<PartyLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<PartyLookupDto>>> Lookup(
        [FromQuery] PartyType? partyType = null, [FromQuery] string? search = null,
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, [FromQuery] int top = 50,
        CancellationToken cancellationToken = default)
    {
        var result = await _partyService.LookupAsync(partyType, search, activeOnly, includeId, top, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The code suggested for a new party of that type (SUP-0001, CLI-0001, SAL-0001, EMP-0001).
    /// Only a suggestion - the user may replace it before saving.
    /// </summary>
    [HttpGet("next-code")]
    [Authorize]
    [ProducesResponseType<NextCodeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<NextCodeDto>> NextCode(
        [FromQuery] PartyType partyType, CancellationToken cancellationToken)
    {
        var result = await _partyService.NextCodeAsync(partyType, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.PartiesView)]
    [ProducesResponseType<PartyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PartyDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _partyService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a party. At least one type flag must be set. A Party Code already in use fails with
    /// code DUPLICATE_CODE; a user already linked to another party fails with USER_ALREADY_LINKED.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.PartiesCreate)]
    [ProducesResponseType<PartyDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PartyDto>> Create(
        [FromBody] SavePartyRequest request, CancellationToken cancellationToken)
    {
        var result = await _partyService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Updates a party. Send the rowVersion read with it to detect concurrent edits. Taking away a
    /// type the party is still used in fails with code TYPE_IN_USE.
    /// </summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.PartiesEdit)]
    [ProducesResponseType<PartyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PartyDto>> Update(
        int id, [FromBody] SavePartyRequest request, CancellationToken cancellationToken)
    {
        var result = await _partyService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a party.</summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.MasterData.PartiesEdit)]
    [ProducesResponseType<PartyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PartyDto>> SetStatus(
        int id, [FromBody] SetPartyStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _partyService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a party no transaction references; otherwise fails with code REFERENCED.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.PartiesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _partyService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
