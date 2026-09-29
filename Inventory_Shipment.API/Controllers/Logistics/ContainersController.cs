using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Containers — the import shipment between the purchase order and the warehouse: loaded from
/// order lines, invoiced from their lines, offloaded at the real cost.
///
/// [HasPermission] ON EVERY ACTION AND THE CHECK AGAIN IN THE SERVICE: the permission of a
/// container action does not depend on the container, so the attribute can say it up front; the
/// service repeats it because it also holds the one rule the attribute cannot — confirming a load
/// above capacity needs containers.overcapacity on top of containers.create.
/// </summary>
[ApiController]
[Route("api/logistics/containers")]
[Produces("application/json")]
public sealed class ContainersController : ControllerBase
{
    /// <summary>PDF, images and office files — what a forwarder, a customs agent or a supplier sends.</summary>
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".tif", ".tiff",
        ".xlsx", ".xls", ".docx", ".doc", ".pptx", ".ppt", ".csv", ".txt",
    };

    private const long MaxFileBytes = 20 * 1024 * 1024;
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IContainerService _containers;

    public ContainersController(IContainerService containers)
    {
        _containers = containers;
    }

    [HttpGet]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<PagedResult<ContainerListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ContainerListDto>>> Search(
        [FromQuery] ContainerQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ContainerDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _containers.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Creates a draft from an approved order (purchaseOrderId); the reference (KTG-yyyy-nnnn) is assigned now and MaxUnits copied from the type.</summary>
    [HttpPost]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Create(
        [FromBody] SaveContainerRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>409 OVER_CAPACITY when the load is above capacity and allowOverCapacity is false (data.canOverride says whether to offer it).</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Update(
        int id, [FromBody] SaveContainerRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/confirm")]
    [HasPermission(Permissions.Containers.Confirm)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Confirm(
        int id, [FromBody] ContainerActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _containers.ConfirmAsync(
            id, request ?? new ContainerActionRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The goods enter stock at the real cost: FOB of the posted invoices + posted charges per piece
    /// received. No lines = everything received as loaded. 409 NOT_FULLY_INVOICED / INVALID_STATUS.
    /// </summary>
    [HttpPost("{id:int}/offload")]
    [HasPermission(Permissions.Containers.Offload)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Offload(
        int id, [FromBody] OffloadRequest? request, CancellationToken cancellationToken)
    {
        var result = await _containers.OffloadAsync(
            id, request ?? new OffloadRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/cancel-offload")]
    [HasPermission(Permissions.Containers.Cancel)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> CancelOffload(
        int id, [FromBody] CancelRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.CancelOffloadAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/close")]
    [HasPermission(Permissions.Containers.Close)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Close(
        int id, [FromBody] ContainerActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _containers.CloseAsync(
            id, request ?? new ContainerActionRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/reopen")]
    [HasPermission(Permissions.Containers.Close)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Reopen(
        int id, [FromBody] ContainerActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _containers.ReopenAsync(
            id, request ?? new ContainerActionRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Containers.Cancel)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> Cancel(
        int id, [FromBody] CancelRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.CancelAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Containers.Delete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _containers.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>The container, its invoices and its lines with FOB / charges / landed per unit.</summary>
    [HttpGet("{id:int}/export")]
    [HasPermission(Permissions.Containers.View)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _containers.ExportAsync(id, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /* ── loading from orders, invoicing from containers ─────────────────────────────────────────── */

    /// <summary>Approved order lines that can still be loaded; containerId = the container being edited.</summary>
    [HttpGet("available-po-lines")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<IReadOnlyList<AvailablePoLineDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<AvailablePoLineDto>>> AvailablePoLines(
        [FromQuery] AvailablePoLineQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.GetAvailablePoLinesAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Container lines still to invoice (purchaseOrderId or containerId required; includeAll = the fully invoiced too).</summary>
    [HttpGet("invoice-candidates")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<IReadOnlyList<InvoiceCandidateDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<InvoiceCandidateDto>>> InvoiceCandidates(
        [FromQuery] InvoiceCandidateQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.GetInvoiceCandidatesAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── many containers per order ────────────────────────────────────────────────────────────── */
    /* Literal routes: the existing {id:int} routes cannot take "auto-plan" or "bulk". */

    /// <summary>The proposed containers of an approved order for one container type (containers, lines, orderLines); nothing is saved.</summary>
    [HttpPost("auto-plan")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<AutoPlanDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<AutoPlanDto>> AutoPlan(
        [FromBody] AutoPlanRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.AutoPlanAsync(request, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates the (edited) plan, all or nothing (201 with the created rows). Send the same capacities
    /// as the proposal. allowOverCapacity needs containers.overcapacity, confirm needs containers.confirm.
    /// 409 OVER_CAPACITY ("Container 3 of 30: ...", data.canOverride) or when an order line is exceeded.
    /// </summary>
    [HttpPost("auto-plan/create")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<IReadOnlyList<CreatedContainerDto>>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<CreatedContainerDto>>> CreateFromPlan(
        [FromBody] CreateContainersFromPlanRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.CreateFromPlanAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Container no. and seal no. of the selected containers (both sent for each; empty clears). 409 DUPLICATE_CONTAINER_NO.</summary>
    [HttpPut("bulk/numbers")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<IReadOnlyList<ContainerNumberDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<ContainerNumberDto>>> SetNumbers(
        [FromBody] ContainerNumbersRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.SetNumbersAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Confirms the drafts among the selected containers; confirmedNow is false for those already confirmed.</summary>
    [HttpPost("bulk/confirm")]
    [HasPermission(Permissions.Containers.Confirm)]
    [ProducesResponseType<IReadOnlyList<ContainerConfirmedDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<IReadOnlyList<ContainerConfirmedDto>>> ConfirmMany(
        [FromBody] IdsRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.ConfirmManyAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes the selected drafts, all or nothing: 409 NOT_EDITABLE names the first that is not a draft.</summary>
    [HttpPost("bulk/delete")]
    [HasPermission(Permissions.Containers.Delete)]
    [ProducesResponseType<ContainersDeletedDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainersDeletedDto>> DeleteMany(
        [FromBody] IdsRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.DeleteManyAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── tracking ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The tracking board: { containers, legs } — open containers and those offloaded during the last offloadedDays days.</summary>
    [HttpGet("tracking")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType<TrackingDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<TrackingDto>> Tracking([FromQuery] TrackingQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.GetTrackingAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Multipart: file, containerIds (repeated), and optionally movementId, chargeId, attachmentTypeId,
    /// note and documentDate (yyyy-MM-dd). The file is stored ONCE and recorded on every container;
    /// the answer is the created records (201).
    /// </summary>
    [HttpPost("attachments")]
    [HasPermission(Permissions.Containers.AttachmentsManage)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType<IReadOnlyList<ContainerAttachmentCreatedDto>>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [RequestSizeLimit(MaxFileBytes + 1024 * 1024)]
    [RequestFormLimits(MultipartBodyLengthLimit = MaxFileBytes + 1024 * 1024)]
    public async Task<IActionResult> AddAttachment(
        IFormFile file, [FromForm] List<int>? containerIds, [FromForm] int? movementId, [FromForm] int? chargeId,
        [FromForm] int? attachmentTypeId, [FromForm] string? note, [FromForm] DateOnly? documentDate,
        CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return Invalid("No file was uploaded.");
        }

        if (file.Length > MaxFileBytes)
        {
            return Invalid($"The file is larger than {MaxFileBytes / (1024 * 1024)} MB.");
        }

        if (!AllowedFileTypes.Contains(Path.GetExtension(file.FileName)))
        {
            return Invalid("Only PDF, image and office files (Word, Excel, PowerPoint, CSV, text) can be attached.");
        }

        if (note is { Length: > 300 })
        {
            return Invalid("The note is longer than 300 characters.");
        }

        using var buffer = new MemoryStream();
        await file.CopyToAsync(buffer, cancellationToken);

        var upload = new ContainerAttachmentUpload
        {
            ContainerIds = containerIds ?? [],
            MovementId = movementId,
            ChargeId = chargeId,
            AttachmentTypeId = attachmentTypeId,
            FileName = Path.GetFileName(file.FileName),
            ContentType = file.ContentType,
            Content = buffer.ToArray(),
            Note = note,
            DocumentDate = documentDate,
        };

        var result = await _containers.AddAttachmentAsync(upload, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, result.Value)
            : this.ToProblem(result);
    }

    [HttpGet("attachments/{id:int}/download")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DownloadAttachment(int id, CancellationToken cancellationToken)
    {
        var result = await _containers.GetAttachmentFileAsync(id, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>allShared = true removes the file from every container holding it.</summary>
    [HttpDelete("attachments/{id:int}")]
    [HasPermission(Permissions.Containers.AttachmentsManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> DeleteAttachment(
        int id, [FromQuery] bool allShared = false, CancellationToken cancellationToken = default)
    {
        var result = await _containers.DeleteAttachmentAsync(id, allShared, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    private IActionResult Invalid(string detail)
        => BadRequest(new ProblemDetails
        {
            Status = StatusCodes.Status400BadRequest,
            Title = "Validation failed",
            Detail = detail,
            Instance = HttpContext.Request.Path,
            Extensions = { ["code"] = "INVALID_FILE" },
        });
}
