using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>Item definitions with their packing units, image and attachments.</summary>
[ApiController]
[Route("api/inventory/items")]
[Produces("application/json")]
public sealed class ItemsController : ControllerBase
{
    private readonly IItemService _itemService;

    public ItemsController(IItemService itemService)
    {
        _itemService = itemService;
    }

    /// <summary>
    /// Paged, filtered and sorted list of items. Filtering by family also matches the items of its
    /// sub-families, and the search box matches item code, item name, SKU and barcode.
    /// </summary>
    [HttpGet]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [ProducesResponseType<PagedResult<ItemListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ItemListDto>>> Search(
        [FromQuery] ItemQuery query, CancellationToken cancellationToken)
    {
        var result = await _itemService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Items for a dropdown, each with the SKU of its base unit. Any signed-in user may read it:
    /// the pages that pick an item are not the pages that maintain items.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<ItemLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ItemLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null,
        [FromQuery] bool salesOnly = false, CancellationToken cancellationToken = default)
    {
        var result = await _itemService.LookupAsync(activeOnly, includeId, salesOnly, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>One item with its units and the metadata of its files.</summary>
    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [ProducesResponseType<ItemDetailsDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ItemDetailsDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _itemService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The item's stock statement - the Stock Movement quick link: the balance brought forward, every movement
    /// (oldest first) with the running balance, across every warehouse, optionally for a date range (yyyy-MM-dd).
    /// </summary>
    [HttpGet("{id:int}/stock-movements")]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [ProducesResponseType<ItemStockStatementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ItemStockStatementDto>> GetStockMovements(
        int id, [FromQuery] DateOnly? from, [FromQuery] DateOnly? to, CancellationToken cancellationToken)
    {
        var result = await _itemService.GetStockStatementAsync(id, from, to, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The item's on hand in every warehouse that has held it, with the totals - the Stock Balance quick link.</summary>
    [HttpGet("{id:int}/stock-balance")]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [ProducesResponseType<ItemStockBalanceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ItemStockBalanceDto>> GetStockBalance(int id, CancellationToken cancellationToken)
    {
        var result = await _itemService.GetStockBalanceAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates an item. Units and files are added afterwards through their own endpoints.
    /// An Item Code already in use fails with code DUPLICATE_CODE.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.Inventory.ItemsCreate)]
    [ProducesResponseType<ItemDetailsDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ItemDetailsDto>> Create(
        [FromBody] SaveItemRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates an item. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType<ItemDetailsDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ItemDetailsDto>> Update(
        int id, [FromBody] SaveItemRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates an item.</summary>
    [HttpPut("{id:int}/status")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> SetStatus(
        int id, [FromBody] SetItemStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Deletes an item with its units and files, unless something references it (REFERENCED).</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Inventory.ItemsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _itemService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }

    // ----- units -----

    /// <summary>
    /// Adds a packing unit and returns the item's refreshed unit list. The first unit of an item must
    /// be the base unit (BASE_UNIT_RULE otherwise).
    /// </summary>
    [HttpPost("{id:int}/units")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType<IReadOnlyList<ItemUnitDto>>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<ItemUnitDto>>> AddUnit(
        int id, [FromBody] SaveItemUnitRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemService.AddUnitAsync(id, request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? Created($"/api/inventory/items/{id}", result.Value)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Edits a packing unit and returns the item's refreshed unit list. Setting isBaseUnit moves the
    /// base to this unit and demotes the previous one.
    /// </summary>
    [HttpPut("{id:int}/units/{unitId:int}")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType<IReadOnlyList<ItemUnitDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<ItemUnitDto>>> UpdateUnit(
        int id, int unitId, [FromBody] SaveItemUnitRequest request, CancellationToken cancellationToken)
    {
        var result = await _itemService.UpdateUnitAsync(id, unitId, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a packing unit. The base unit cannot be deleted (BASE_UNIT_RULE).</summary>
    [HttpDelete("{id:int}/units/{unitId:int}")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> DeleteUnit(int id, int unitId, CancellationToken cancellationToken)
    {
        var result = await _itemService.DeleteUnitAsync(id, unitId, cancellationToken);
        return result.ToNoContentResult(this);
    }

    // ----- files -----

    /// <summary>
    /// Uploads a file against the item (multipart/form-data). With isItemImage=true it becomes the
    /// item's picture and replaces the previous one; max 5 MB.
    /// </summary>
    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(6 * 1024 * 1024)]
    [ProducesResponseType<ItemFileDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ItemFileDto>> AddFile(
        int id, IFormFile file, [FromQuery] bool isItemImage = false, CancellationToken cancellationToken = default)
    {
        if (file is null)
        {
            return BadRequest(new ProblemDetails
            {
                Status = StatusCodes.Status400BadRequest,
                Title = "Validation failed",
                Detail = "No file was uploaded.",
                Instance = HttpContext.Request.Path,
                Extensions = { ["code"] = "VALIDATION" }
            });
        }

        await using var stream = file.OpenReadStream();
        var upload = new ItemFileUpload(file.FileName, file.ContentType, file.Length, stream);

        var result = await _itemService.AddFileAsync(id, upload, isItemImage, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? Created($"/api/inventory/items/{id}/files/{result.Value!.Id}", result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Downloads one of the item's files - images render inline, everything else downloads.</summary>
    [HttpGet("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Inventory.ItemsView)]
    [Produces("application/octet-stream")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _itemService.GetFileAsync(id, fileId, cancellationToken);

        if (result.IsFailure)
        {
            return this.ToProblem(result);
        }

        var file = result.Value!;

        // Pictures are shown in the page; documents should land in the Downloads folder.
        return file.ContentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
            ? File(file.Content, file.ContentType)
            : File(file.Content, file.ContentType, file.FileName);
    }

    /// <summary>
    /// Edits one of the item's files (multipart/form-data): fileName renames it, and an optional file
    /// replaces its content under the upload's checks. Without a file the stored one is kept.
    /// </summary>
    [HttpPut("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(6 * 1024 * 1024)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> UpdateFile(
        int id, int fileId, [FromForm] string? fileName, IFormFile? file, CancellationToken cancellationToken = default)
    {
        await using var stream = file?.OpenReadStream();
        var upload = file is null ? null : new ItemFileUpload(file.FileName, file.ContentType, file.Length, stream!);

        var result = await _itemService.UpdateFileAsync(id, fileId, fileName, upload, cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Deletes one of the item's files.</summary>
    [HttpDelete("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Inventory.ItemsEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _itemService.DeleteFileAsync(id, fileId, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
