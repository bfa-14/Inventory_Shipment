using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// The category / sub type of a file (Shipping / Bill of Lading, Purchase / Proforma Invoice...) and the document
/// kinds it is used for (script 52). One "manage" permission for the list page and the writes; what an upload
/// dialog reads - the types of a document kind, the lookup, the kinds - is open to any signed-in user.
/// </summary>
[ApiController]
[Route("api/masterdata/attachment-types")]
[Produces("application/json")]
public sealed class AttachmentTypesController : ControllerBase
{
    private readonly IAttachmentTypeService _attachmentTypes;

    public AttachmentTypesController(IAttachmentTypeService attachmentTypes)
    {
        _attachmentTypes = attachmentTypes;
    }

    /// <summary>
    /// The list page (attachment types manage). With documentKind (CONTAINER, PO, PINV...): the types used for that
    /// kind, the active ones unless isActive says otherwise - what its upload dialog offers - for anyone signed in.
    /// </summary>
    [HttpGet]
    [Authorize]
    [ProducesResponseType<PagedResult<AttachmentTypeDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<PagedResult<AttachmentTypeDto>>> Search([FromQuery] AttachmentTypeQuery query, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The document kinds a type can be used for: [{ code, name }], in the order of the pages.</summary>
    [HttpGet("document-kinds")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<AttachmentDocumentKindDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<AttachmentDocumentKindDto>>> DocumentKinds(CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.GetDocumentKindsAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<AttachmentTypeLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<AttachmentTypeLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, [FromQuery] string? appliesTo = null,
        [FromQuery] string? documentKind = null, CancellationToken cancellationToken = default)
    {
        var result = await _attachmentTypes.LookupAsync(activeOnly, includeId, appliesTo, documentKind, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.AttachmentTypesManage)]
    [ProducesResponseType<AttachmentTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<AttachmentTypeDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A code already in use fails with 409 DUPLICATE_CODE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.AttachmentTypesManage)]
    [ProducesResponseType<AttachmentTypeDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<AttachmentTypeDto>> Create([FromBody] SaveAttachmentTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.AttachmentTypesManage)]
    [ProducesResponseType<AttachmentTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<AttachmentTypeDto>> Update(int id, [FromBody] SaveAttachmentTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps a used row readable on old containers; deleting is for one nothing has used.</summary>
    [HttpPost("{id:int}/set-active")]
    [HasPermission(Permissions.MasterData.AttachmentTypesManage)]
    [ProducesResponseType<AttachmentTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<AttachmentTypeDto>> SetActive(
        int id, [FromBody] SetLogisticsMasterActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.SetActiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 IN_USE when containers use it.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.AttachmentTypesManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
