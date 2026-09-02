using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>Product brands (master data referenced by items).</summary>
[ApiController]
[Route("api/masterdata/brands")]
[Produces("application/json")]
public sealed class BrandsController : ControllerBase
{
    private readonly IBrandService _brandService;

    public BrandsController(IBrandService brandService)
    {
        _brandService = brandService;
    }

    /// <summary>Paged, filtered and sorted list of brands.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.BrandsView)]
    [ProducesResponseType<PagedResult<BrandDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<BrandDto>>> Search(
        [FromQuery] BrandQuery query, CancellationToken cancellationToken)
    {
        var result = await _brandService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Brands for a Brand dropdown. Any signed-in user may read it: every form with a Brand picker
    /// needs it, not only the users who administer brands.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<BrandLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<BrandLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _brandService.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.BrandsView)]
    [ProducesResponseType<BrandDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<BrandDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _brandService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Creates a brand. A Brand Code already in use fails with code DUPLICATE_CODE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.BrandsCreate)]
    [ProducesResponseType<BrandDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<BrandDto>> Create(
        [FromBody] SaveBrandRequest request, CancellationToken cancellationToken)
    {
        var result = await _brandService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates a brand. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.BrandsEdit)]
    [ProducesResponseType<BrandDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<BrandDto>> Update(
        int id, [FromBody] SaveBrandRequest request, CancellationToken cancellationToken)
    {
        var result = await _brandService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a brand.</summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.MasterData.BrandsEdit)]
    [ProducesResponseType<BrandDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<BrandDto>> SetStatus(
        int id, [FromBody] SetBrandStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _brandService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a brand that no other record references.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.BrandsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _brandService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
