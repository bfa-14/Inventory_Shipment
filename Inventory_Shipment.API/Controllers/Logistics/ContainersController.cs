using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Containers — the import shipment between the purchase invoice and the warehouse.
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
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".xlsx", ".xls", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    };

    private const long MaxFileBytes = 10 * 1024 * 1024;
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

    /// <summary>Creates a draft; the reference (KTG-yyyy-nnnn) is assigned now and MaxUnits copied from the type.</summary>
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

    [HttpPost("{id:int}/events")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<ContainerDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ContainerDto>> AddEvent(
        int id, [FromBody] AddEventRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.AddEventAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The goods enter stock at the invoice landed cost. No lines = everything received as loaded.</summary>
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

    /* ── loading: the invoices and their lines ────────────────────────────────────────────────── */

    /// <summary>Purchase invoices (draft or posted, not cancelled) with something left to load.</summary>
    [HttpGet("available-invoices")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<IReadOnlyList<AvailableInvoiceDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<AvailableInvoiceDto>>> AvailableInvoices(
        [FromQuery] AvailableInvoiceQuery query, CancellationToken cancellationToken)
    {
        var result = await _containers.GetAvailableInvoicesAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The lines of one invoice for the loading grid; containerId = the container being edited.</summary>
    [HttpGet("available-invoices/{invoiceId:int}/lines")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType<IReadOnlyList<AvailableInvoiceLineDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<AvailableInvoiceLineDto>>> InvoiceLines(
        int invoiceId, [FromQuery] int? containerId, CancellationToken cancellationToken)
    {
        var result = await _containers.GetInvoiceLinesAsync(invoiceId, containerId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>Multipart: file, and optionally attachmentTypeId, note and documentDate (yyyy-MM-dd).</summary>
    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Containers.Create)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [RequestSizeLimit(MaxFileBytes * 2)]
    public async Task<IActionResult> AddFile(
        int id, IFormFile file, [FromForm] int? attachmentTypeId, [FromForm] string? note, [FromForm] DateOnly? documentDate,
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
            return Invalid("Only PDF, Excel, Word and image files can be attached.");
        }

        if (note is { Length: > 300 })
        {
            return Invalid("The note is longer than 300 characters.");
        }

        using var buffer = new MemoryStream();
        await file.CopyToAsync(buffer, cancellationToken);

        var upload = new ContainerFileUpload
        {
            FileName = file.FileName,
            ContentType = file.ContentType,
            Content = buffer.ToArray(),
            AttachmentTypeId = attachmentTypeId,
            Note = note,
            DocumentDate = documentDate,
        };

        var result = await _containers.AddFileAsync(id, upload, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    [HttpGet("files/{fileId:int}")]
    [HasPermission(Permissions.Containers.View)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int fileId, CancellationToken cancellationToken)
    {
        var result = await _containers.GetFileAsync(fileId, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    [HttpDelete("files/{fileId:int}")]
    [HasPermission(Permissions.Containers.Create)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> DeleteFile(int fileId, CancellationToken cancellationToken)
    {
        var result = await _containers.DeleteFileAsync(fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
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
