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
/// The category / sub type of a container file (Shipping / Bill of Lading, Customs / FERI...).
/// One "manage" permission for the list and the writes; the LOOKUP is open to any signed-in user,
/// because the container page picks from it.
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

    [HttpGet]
    [HasPermission(Permissions.MasterData.AttachmentTypesManage)]
    [ProducesResponseType<PagedResult<AttachmentTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<AttachmentTypeDto>>> Search([FromQuery] AttachmentTypeQuery query, CancellationToken cancellationToken)
    {
        var result = await _attachmentTypes.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<AttachmentTypeLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<AttachmentTypeLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, [FromQuery] string? appliesTo = null,
        CancellationToken cancellationToken = default)
    {
        var result = await _attachmentTypes.LookupAsync(activeOnly, includeId, appliesTo, cancellationToken);
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
