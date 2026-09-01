using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// Item families - one self-referencing tree of unlimited depth that replaces the older
/// "sub groups" / "categories" split. Items attach to a family at any level, codes are stable
/// (a move never renames them), and a family can be active only while its parent is.
/// </summary>
[ApiController]
[Route("api/masterdata/item-families")]
[Produces("application/json")]
public sealed class ItemFamiliesController : ControllerBase
{
    private readonly IItemFamilyService _itemFamilyService;

    public ItemFamiliesController(IItemFamilyService itemFamilyService)
    {
        _itemFamilyService = itemFamilyService;
    }

    /// <summary>
    /// Every family as a flat list ordered by level then code, each row carrying its parentId, level and
    /// childCount. There is no paging on purpose - paging cannot work on a tree, so the client loads the
    /// whole set once and nests it itself.
    /// </summary>
    [HttpGet("tree")]
    [HasPermission(Permissions.MasterData.ItemFamiliesView)]
    [ProducesResponseType<IReadOnlyList<ItemFamilyDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ItemFamilyDto>>> Tree(CancellationToken cancellationToken)
    {
        var result = await _itemFamilyService.TreeAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Families for a dropdown. Any signed-in user may read it: forms all over the application offer a
    /// family to pick, not only the users who administer the tree.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<ItemFamilyLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ItemFamilyLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null,
        CancellationToken cancellationToken = default)
    {
        var result = await _itemFamilyService.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The code suggested for a new family under <paramref name="parentId"/> (FAM-### for a root,
    /// &lt;parent code&gt;-## below one). Only a suggestion - the user may replace it before saving.
    /// </summary>
    [HttpGet("next-code")]
    [Authorize]
    [ProducesResponseType<NextCodeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<NextCodeDto>> NextCode(
        [FromQuery] int? parentId = null, CancellationToken cancellationToken = default)
    {
        var result = await _itemFamilyService.NextChildCodeAsync(parentId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.ItemFamiliesView)]
    [ProducesResponseType<ItemFamilyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ItemFamilyDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _itemFamilyService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a family. A null parentId creates a root. The code must be unique across the whole tree
    /// (DUPLICATE_CODE) and the name unique among its siblings (DUPLICATE_NAME); an active family cannot
    /// be created under an inactive parent (PARENT_INACTIVE).
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.ItemFamiliesCreate)]
    [ProducesResponseType<ItemFamilyDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ItemFamilyDto>> Create(
        [FromBody] SaveItemFamilyRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemFamilyService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Updates a family. Changing parentId moves it and re-levels its whole subtree; choosing one of its
    /// own descendants fails with CIRCULAR_HIERARCHY. Sending isActive = false cascades to the subtree.
    /// Send the rowVersion read with the family to detect concurrent edits.
    /// </summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.ItemFamiliesEdit)]
    [ProducesResponseType<ItemFamilyDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ItemFamilyDto>> Update(
        int id, [FromBody] SaveItemFamilyRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemFamilyService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Activates or deactivates a family. Deactivating also deactivates every descendant; activating one
    /// whose parent is inactive fails with PARENT_INACTIVE.
    /// </summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.MasterData.ItemFamiliesEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> SetStatus(
        int id, [FromBody] SetItemFamilyStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemFamilyService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>
    /// Deletes a family that has no children (HAS_CHILDREN) and that nothing else references
    /// (REFERENCED). Deactivating is the alternative in both cases.
    /// </summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.ItemFamiliesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _itemFamilyService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
