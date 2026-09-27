using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// Purchase orders, purchase invoices and purchase returns — one engine behind one route.
///
/// [Authorize] RATHER THAN [HasPermission] ON THE ACTIONS: the permission an action needs is the
/// document's kind to tell (purchase.orders.post for an order, purchase.invoices.post for an
/// invoice), and the kind is only known once the document is read. The service reads it and
/// answers 403 with code FORBIDDEN naming the permission that was missing.
/// </summary>
[ApiController]
[Authorize]
[Route("api/purchase/documents")]
[Produces("application/json")]
public sealed class PurchaseDocumentsController : ControllerBase
{
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".xlsx", ".xls", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    };

    private const long MaxFileBytes = 10 * 1024 * 1024;
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IPurchaseDocumentService _documents;

    public PurchaseDocumentsController(IPurchaseDocumentService documents)
    {
        _documents = documents;
    }

    [HttpGet]
    [ProducesResponseType<PagedResult<PurchaseDocumentListDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<PagedResult<PurchaseDocumentListDto>>> Search(
        [FromQuery] PurchaseDocumentQuery query, CancellationToken cancellationToken)
    {
        var result = await _documents.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PurchaseDocumentDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _documents.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<PurchaseDocumentDto>> Create(
        [FromBody] SavePurchaseDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.SaveDraftAsync(
            null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> Update(
        int id, [FromBody] SavePurchaseDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.SaveDraftAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/post")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> Post(
        int id, [FromBody] PostPurchaseDocumentRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.PostAsync(
            id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/cancel")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> Cancel(
        int id, [FromBody] CancelPurchaseDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.CancelAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/close")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> Close(
        int id, [FromBody] ClosePurchaseDocumentRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.CloseAsync(
            id, request ?? new ClosePurchaseDocumentRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// The charges of a DRAFT purchase invoice — freight, customs, clearing — replacing whatever was
    /// there. Sent apart from the lines: the lines are the supplier's bill and the charges are
    /// everybody else's, and they are refused for different reasons.
    /// </summary>
    [HttpPut("{id:int}/charges")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> SetCharges(
        int id, [FromBody] SetPurchaseChargesRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.SetChargesAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>What the supplier has shipped on an open order (in transit until received). No lines = everything shipped.</summary>
    [HttpPost("{id:int}/mark-shipped")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> MarkShipped(
        int id, [FromBody] MarkShippedRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.MarkShippedAsync(
            id, request ?? new MarkShippedRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _documents.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /* ── the chain ────────────────────────────────────────────────────────────────────────────── */

    [HttpPost("{id:int}/create-invoice")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public Task<ActionResult<PurchaseDocumentDto>> CreateInvoice(
        int id, [FromBody] CreateFromSourceRequest? request, CancellationToken cancellationToken)
        => CreateFromSource(id, PurchaseDocumentTypes.Invoice, request, cancellationToken);

    [HttpPost("{id:int}/create-return")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public Task<ActionResult<PurchaseDocumentDto>> CreateReturn(
        int id, [FromBody] CreateFromSourceRequest? request, CancellationToken cancellationToken)
        => CreateFromSource(id, PurchaseDocumentTypes.Return, request, cancellationToken);

    /// <summary>
    /// A draft purchase invoice from container lines of the order: body { documentDate?, lines?:
    /// [{ containerLineId, quantityBase }] } — no lines = everything loaded and not yet invoiced.
    /// Answers { id } of the new draft (purchase.invoices.create).
    /// </summary>
    [HttpPost("{id:int}/invoice-from-containers")]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> InvoiceFromContainers(
        int id, [FromBody] InvoiceFromContainersRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.CreateFromContainersAsync(
            id, request ?? new InvoiceFromContainersRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value }, new { id = result.Value })
            : this.ToProblem(result);
    }

    private async Task<ActionResult<PurchaseDocumentDto>> CreateFromSource(
        int id, string targetTypeCode, CreateFromSourceRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.CreateFromSourceAsync(
            id, targetTypeCode, request ?? new CreateFromSourceRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /* ── bulk and import ──────────────────────────────────────────────────────────────────────── */

    [HttpPost("bulk-post")]
    [ProducesResponseType<BulkActionResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<BulkActionResult>> BulkPost(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
        => Ok(await _documents.BulkPostAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken));

    [HttpPost("bulk-delete")]
    [ProducesResponseType<BulkActionResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<BulkActionResult>> BulkDelete(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
        => Ok(await _documents.BulkDeleteAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken));

    [HttpPost("import-create")]
    [ProducesResponseType<ImportCreateResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ImportCreateResult>> ImportCreate(
        [FromBody] ImportCreatePurchaseDocumentsRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.ImportCreateAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    [HttpGet("{id:int}/export")]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _documents.ExportAsync(id, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    [HttpPost("{id:int}/files")]
    [Consumes("multipart/form-data")]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [RequestSizeLimit(MaxFileBytes * 2)]
    public async Task<IActionResult> AddFile(int id, IFormFile file, CancellationToken cancellationToken)
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

        using var buffer = new MemoryStream();
        await file.CopyToAsync(buffer, cancellationToken);

        var result = await _documents.AddFileAsync(
            id, file.FileName, file.ContentType, buffer.ToArray(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    [HttpGet("{id:int}/files/{fileId:int}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _documents.GetFileAsync(id, fileId, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    [HttpDelete("{id:int}/files/{fileId:int}")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _documents.DeleteFileAsync(id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
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
