using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.Shortages;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// Shortage plans: a saved planning document — Draft (editable, recalculable, deletable) → Posted
/// (a read-only historical snapshot that purchase orders are created from).
/// </summary>
[ApiController]
[Route("api/inventory/shortages")]
[Produces("application/json")]
public sealed class ShortageDocumentsController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IShortageDocumentService _shortages;

    public ShortageDocumentsController(IShortageDocumentService shortages)
    {
        _shortages = shortages;
    }

    /// <summary>The LIVE rows of one warehouse — what "Load items" puts into a draft. Not paged.</summary>
    [HttpGet("calculate")]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [ProducesResponseType<IReadOnlyList<ShortageLiveRowDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<ShortageLiveRowDto>>> Calculate(
        [FromQuery] ShortageCalculateQuery query, CancellationToken cancellationToken)
    {
        var result = await _shortages.CalculateAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("calculate/export")]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> ExportLive([FromQuery] ShortageCalculateQuery query, CancellationToken cancellationToken)
    {
        var result = await _shortages.ExportLiveAsync(query, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    [HttpGet]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [ProducesResponseType<PagedResult<ShortageDocumentListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ShortageDocumentListDto>>> Search(
        [FromQuery] ShortageDocumentQuery query, CancellationToken cancellationToken)
    {
        var result = await _shortages.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [ProducesResponseType<ShortageDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ShortageDocumentDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _shortages.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A new draft. The number (SHR-2026-000001) is assigned now; the figures are the live ones of this moment.</summary>
    [HttpPost]
    [HasPermission(Permissions.Inventory.ShortagesCreate)]
    [ProducesResponseType<ShortageDocumentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<ShortageDocumentDto>> Create(
        [FromBody] SaveShortageDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _shortages.SaveDraftAsync(
            null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Inventory.ShortagesCreate)]
    [ProducesResponseType<ShortageDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ShortageDocumentDto>> Update(
        int id, [FromBody] SaveShortageDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _shortages.SaveDraftAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Draft only: the live figures again; required quantities, manual sales and PC per container are kept.</summary>
    [HttpPost("{id:int}/recalculate")]
    [HasPermission(Permissions.Inventory.ShortagesCreate)]
    [ProducesResponseType<ShortageDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ShortageDocumentDto>> Recalculate(
        int id, [FromBody] ShortageDocumentActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _shortages.RecalculateAsync(
            id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Inventory.ShortagesPost)]
    [ProducesResponseType<ShortageDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ShortageDocumentDto>> Post(
        int id, [FromBody] ShortageDocumentActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _shortages.PostAsync(
            id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Inventory.ShortagesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _shortages.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    [HttpGet("{id:int}/export")]
    [HasPermission(Permissions.Inventory.ShortagesView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _shortages.ExportAsync(id, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>Posted plans only: one draft purchase order for the plan's supplier, branch and warehouse.</summary>
    [HttpPost("{id:int}/create-purchase-order")]
    [HasPermission(Permissions.Purchase.OrdersCreate)]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> CreatePurchaseOrder(
        int id, [FromBody] CreatePurchaseOrderFromShortageRequest? request, CancellationToken cancellationToken)
    {
        var result = await _shortages.CreatePurchaseOrderAsync(
            id, request ?? new CreatePurchaseOrderFromShortageRequest(), User.GetUserId(), User.GetPermissions(),
            cancellationToken);

        return result.ToActionResult(this);
    }
}
