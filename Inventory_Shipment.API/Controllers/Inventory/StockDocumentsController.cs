using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// Inventory In and Inventory Out documents — the first document family, and the shape Purchase and
/// Sales will copy.
///
/// ONE CONTROLLER, TWO DOCUMENT KINDS, AND THEREFORE NO [HasPermission] ON THE ACTIONS. Which
/// permission applies depends on the document's TYPE (inventory.stockin.* against
/// inventory.stockout.*), and for an existing document that is only known after reading it — which is
/// after the attribute would have run. So every action is [Authorize] and the service makes the
/// check where the answer exists, returning Forbidden the same way the attribute would.
///
/// A DOCUMENT IS ALWAYS RETURNED WHOLE. Save, post and cancel all answer with the re-read document
/// rather than with an acknowledgement: posting assigns the number, writes the ledger and moves the
/// status, and a client that had to guess which of those happened would be reimplementing the
/// procedure.
/// </summary>
[ApiController]
[Route("api/inventory/stock-documents")]
[Produces("application/json")]
[Authorize]
public sealed class StockDocumentsController : ControllerBase
{
    /// <summary>What an attachment may be. Anything else is a file somebody meant to send elsewhere.</summary>
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".xlsx", ".xls", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    };

    private const long MaxFileBytes = 10 * 1024 * 1024;
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IStockDocumentService _documents;

    public StockDocumentsController(IStockDocumentService documents)
    {
        _documents = documents;
    }

    /// <summary>Paged, filtered and sorted documents of one kind. documentTypeCode is required.</summary>
    [HttpGet]
    [ProducesResponseType<PagedResult<StockDocumentListDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<PagedResult<StockDocumentListDto>>> Search(
        [FromQuery] StockDocumentQuery query, CancellationToken cancellationToken)
    {
        var result = await _documents.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType<StockDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<StockDocumentDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _documents.GetAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Creates a draft. Nothing reaches the stock ledger until it is posted.</summary>
    [HttpPost]
    [ProducesResponseType<StockDocumentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<StockDocumentDto>> Create(
        [FromBody] SaveStockDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.SaveDraftAsync(
            null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Replaces a draft, lines and all. A posted document is refused with NOT_DRAFT.</summary>
    [HttpPut("{id:int}")]
    [ProducesResponseType<StockDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<StockDocumentDto>> Update(
        int id, [FromBody] SaveStockDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.SaveDraftAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// Posts a draft: the ledger is written and the document becomes read-only.
    ///
    /// THE ONE IRREVERSIBLE STEP — a posted document is never edited or deleted, only cancelled, which
    /// writes a reversal rather than erasing anything. An Out that would take stock below zero is
    /// refused here with INSUFFICIENT_STOCK and the procedure's own figures.
    /// </summary>
    [HttpPost("{id:int}/post")]
    [ProducesResponseType<StockDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<StockDocumentDto>> Post(
        int id, [FromBody] PostStockDocumentRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.PostAsync(
            id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Cancels a posted document by writing the opposite movements. The reason is required.</summary>
    [HttpPost("{id:int}/cancel")]
    [ProducesResponseType<StockDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<StockDocumentDto>> Cancel(
        int id, [FromBody] CancelStockDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.CancelAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _documents.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>The document as a workbook, for filing or for sending to somebody without a login.</summary>
    [HttpGet("{id:int}/export")]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
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

        var extension = Path.GetExtension(file.FileName);
        if (!AllowedFileTypes.Contains(extension))
        {
            return Invalid("Only PDF, Excel, Word and image files can be attached.");
        }

        // Read here rather than streaming to SQL: the ceiling is 10 MB, the procedure takes a
        // VARBINARY(MAX) parameter, and a stream would buy nothing at this size.
        using var buffer = new MemoryStream();
        await file.CopyToAsync(buffer, cancellationToken);

        var result = await _documents.AddFileAsync(
            id, file.FileName, file.ContentType, buffer.ToArray(), User.GetUserId(),
            User.GetPermissions(), cancellationToken);

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
        var result = await _documents.DeleteFileAsync(
            id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);

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

/// <summary>
/// The configuration and lookups the document screens read: what kinds of document exist, what
/// reasons they may carry, and how much stock there is right now.
///
/// SEPARATE FROM THE DOCUMENTS CONTROLLER because they are not documents and they are not gated the
/// same way. Any signed-in user may read them — every form with a Reason picker needs the list, not
/// only the people who post stock — and the on-hand figure is what the line grid shows while
/// somebody is still typing.
/// </summary>
[ApiController]
[Route("api/inventory")]
[Produces("application/json")]
[Authorize]
public sealed class InventoryLookupsController : ControllerBase
{
    private readonly IStockDocumentService _documents;

    public InventoryLookupsController(IStockDocumentService documents)
    {
        _documents = documents;
    }

    /// <summary>All eight document kinds and their numbering rules.</summary>
    [HttpGet("document-types")]
    [ProducesResponseType<IReadOnlyList<DocumentTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<DocumentTypeDto>>> GetDocumentTypes(CancellationToken cancellationToken)
    {
        var result = await _documents.GetDocumentTypesAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Reasons for one direction: 1 for In, -1 for Out, omitted for all.</summary>
    [HttpGet("stock-reasons")]
    [ProducesResponseType<IReadOnlyList<StockReasonDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<StockReasonDto>>> GetStockReasons(
        [FromQuery] short? direction, CancellationToken cancellationToken)
    {
        var result = await _documents.GetStockReasonsAsync(direction, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Stock in one item and warehouse, in base units — the line grid's On Hand column.</summary>
    [HttpGet("stock/on-hand")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> GetOnHand(
        [FromQuery] int itemId, [FromQuery] int warehouseId, CancellationToken cancellationToken)
    {
        var result = await _documents.GetOnHandAsync(itemId, warehouseId, cancellationToken);

        return result.IsSuccess
            ? Ok(new { onHandBase = result.Value })
            : this.ToProblem(result);
    }
}
