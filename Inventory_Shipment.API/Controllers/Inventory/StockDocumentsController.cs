using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Security;
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
    /// <summary>
    /// Posts several drafts at once — each in its own transaction, so one refusal leaves the others
    /// posted. The result says, id by id, what happened. [Authorize] like every action here: the
    /// per-document permission is checked by the service against each document's own type.
    /// </summary>
    [HttpPost("bulk-post")]
    [ProducesResponseType<BulkActionResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<BulkActionResult>> BulkPost(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
        => Ok(await _documents.BulkPostAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken));

    /// <summary>Deletes several drafts; a posted document among them fails alone with NOT_DRAFT.</summary>
    [HttpPost("bulk-delete")]
    [ProducesResponseType<BulkActionResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<BulkActionResult>> BulkDelete(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
        => Ok(await _documents.BulkDeleteAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken));

    /// <summary>
    /// An imported file becoming ONE document holding every line, each in the warehouse it names,
    /// posted at once when asked. A refused posting leaves the document as a draft, listed in Failed.
    /// </summary>
    [HttpPost("import-create")]
    [ProducesResponseType<ImportCreateResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ImportCreateResult>> ImportCreate(
        [FromBody] ImportCreateStockDocumentsRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.ImportCreateAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

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

    /// <summary>
    /// Multipart: file, attachmentTypeId (required: a type used for the document's kind - INV_IN or INV_OUT), and optionally documentDate
    /// (yyyy-MM-dd) and note. PDF, image or Office file, up to 20 MB.
    /// </summary>
    [HttpPost("{id:int}/files")]
    [Consumes("multipart/form-data")]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [RequestSizeLimit(AttachmentRules.MaxRequestBytes)]
    [RequestFormLimits(MultipartBodyLengthLimit = AttachmentRules.MaxRequestBytes)]
    public async Task<IActionResult> AddFile(
        int id, IFormFile file, [FromForm] int? attachmentTypeId, [FromForm] DateOnly? documentDate, [FromForm] string? note,
        CancellationToken cancellationToken)
    {
        var fields = new DocumentFileFields { AttachmentTypeId = attachmentTypeId, DocumentDate = documentDate, Note = note };
        if (this.RefuseUpload(file, fields) is { } refusal)
        {
            return refusal;
        }

        using var buffer = new MemoryStream();
        await file.CopyToAsync(buffer, cancellationToken);

        var result = await _documents.AddFileAsync(
            id, file.FileName, file.ContentType, buffer.ToArray(), fields, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    /// <summary>The files with their type, date and note, newest first; attachmentTypeId = one type only.</summary>
    [HttpGet("{id:int}/files")]
    [ProducesResponseType<IReadOnlyList<DocumentFileDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<DocumentFileDto>>> ListFiles(
        int id, [FromQuery] int? attachmentTypeId, CancellationToken cancellationToken)
    {
        var result = await _documents.ListFilesAsync(id, attachmentTypeId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
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

    /// <summary>
    /// Multipart: fileName (required), attachmentTypeId (required, as for the upload), and optionally documentDate
    /// (yyyy-MM-dd), note and a file that replaces the stored one in the same place in the list (none keeps it). The
    /// upload's permission and checks; answers the file's row.
    /// </summary>
    [HttpPut("{id:int}/files/{fileId:int}")]
    [Consumes("multipart/form-data")]
    [ProducesResponseType<DocumentFileDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [RequestSizeLimit(AttachmentRules.MaxRequestBytes)]
    [RequestFormLimits(MultipartBodyLengthLimit = AttachmentRules.MaxRequestBytes)]
    public async Task<ActionResult<DocumentFileDto>> UpdateFile(
        int id, int fileId, [FromForm] string? fileName, [FromForm] int? attachmentTypeId, [FromForm] DateOnly? documentDate,
        [FromForm] string? note, IFormFile? file, CancellationToken cancellationToken)
    {
        var fields = new DocumentFileFields { AttachmentTypeId = attachmentTypeId, DocumentDate = documentDate, Note = note };
        var (edit, refusal) = await this.ReadEditAsync(fileName, fields, file, cancellationToken);
        if (refusal is not null)
        {
            return refusal;
        }

        var result = await _documents.UpdateFileAsync(id, fileId, edit!, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}/files/{fileId:int}")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _documents.DeleteFileAsync(
            id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToNoContentResult(this);
    }
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

    /// <summary>
    /// The configuration page's save. GUARDED BY ITS OWN PERMISSION where the read is open to every
    /// signed-in user: every document page reads the list; one business owner changes it.
    /// </summary>
    [HttpPut("document-types/{id:int}")]
    [HasPermission(Permissions.Configuration.DocumentTypesManage)]
    [ProducesResponseType<DocumentTypeDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<DocumentTypeDto>> UpdateDocumentType(
        int id, [FromBody] UpdateDocumentTypeRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.UpdateDocumentTypeAsync(id, request, User.GetUserId(), cancellationToken);
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
