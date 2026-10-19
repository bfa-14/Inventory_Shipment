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

    /// <summary>
    /// Posts the document. Since script 65 a supplier invoice moves no stock: the answer's postResult says what the posting
    /// did to the cost of goods already received, and, with receiveNow (a supplier invoice; needs the goods receipt create
    /// and post rights too), the goods receipt made at once - or the warning saying why it was not, the invoice posted.
    /// </summary>
    [HttpPost("{id:int}/post")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PurchaseDocumentDto>> Post(
        int id, [FromBody] PostPurchaseDocumentRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.PostWithOptionsAsync(
            id, request ?? new PostPurchaseDocumentRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// The post confirmation of a DRAFT supplier invoice: what posting it would do to the cost of the goods already
    /// received (an estimate on today's stock) - "60 pcs already received will have their cost adjusted by +60.00 USD
    /// (estimate: stock 40.00, cost of sales 20.00)." Needs purchase.invoices.post.
    /// </summary>
    [HttpGet("{id:int}/receipt-cost-preview")]
    [ProducesResponseType<ReceiptCostPreviewDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ReceiptCostPreviewDto>> ReceiptCostPreview(int id, CancellationToken cancellationToken)
    {
        var result = await _documents.ReceiptCostPreviewAsync(id, User.GetPermissions(), cancellationToken);
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

    /// <summary>
    /// The order's lines still to invoice, for "Create Purchase Invoice" (script 86): per line ordered, invoiced by posted
    /// invoices, in draft invoices and available, in base units (includeAll = the fully invoiced lines too). Needs seeing
    /// the order.
    /// </summary>
    [HttpGet("{id:int}/invoice-candidates")]
    [ProducesResponseType<IReadOnlyList<OrderInvoiceCandidateDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<OrderInvoiceCandidateDto>>> InvoiceCandidates(
        int id, [FromQuery] bool includeAll, CancellationToken cancellationToken)
    {
        var result = await _documents.GetOrderInvoiceCandidatesAsync(id, includeAll, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Draft purchase invoices holding what remains to receive on the order: ONE PER ITEM (a supplier invoice
    /// holds one item), or ONE holding every item. Body { documentDate?, lines?, exporterReference?,
    /// commercialInvoiceNo?, onePerItem? } — lines [{ sourceLineId, quantityBase }] = the order lines and pieces to
    /// take (script 86; none = everything still available); the references are copied to every invoice; onePerItem true
    /// = one invoice per item, false = one invoice of every item, null = the setting Purchase.OneItemPerInvoice (script
    /// 63). Answers { firstId, id (= firstId), invoices, message }.
    /// </summary>
    [HttpPost("{id:int}/create-invoice")]
    [ProducesResponseType<CreatedPurchaseInvoicesDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CreatedPurchaseInvoicesDto>> CreateInvoice(
        int id, [FromBody] CreateFromSourceRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.CreateInvoicesFromOrderAsync(
            id, request ?? new CreateFromSourceRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.FirstId }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPost("{id:int}/create-return")]
    [ProducesResponseType<PurchaseDocumentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public Task<ActionResult<PurchaseDocumentDto>> CreateReturn(
        int id, [FromBody] CreateFromSourceRequest? request, CancellationToken cancellationToken)
        => CreateFromSource(id, PurchaseDocumentTypes.Return, request, cancellationToken);

    /// <summary>
    /// Draft purchase invoices from container lines of the order, ONE PER ITEM or one of every item: body
    /// { documentDate?, lines?: [{ containerLineId, quantityBase }], exporterReference?, commercialInvoiceNo?,
    /// onePerItem? } — no lines = everything loaded and not yet invoiced; onePerItem as for create-invoice (null = the
    /// setting). Answers { firstId, id (= firstId), invoices, message } (purchase.invoices.create).
    /// </summary>
    [HttpPost("{id:int}/invoice-from-containers")]
    [ProducesResponseType<CreatedPurchaseInvoicesDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CreatedPurchaseInvoicesDto>> InvoiceFromContainers(
        int id, [FromBody] InvoiceFromContainersRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.CreateFromContainersAsync(
            id, request ?? new InvoiceFromContainersRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.FirstId }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>
    /// A draft purchase invoice holding several items (made before one item per invoice, or one that may hold several)
    /// into one invoice per item, each of one item from then on: body { rowVersion }. Answers { invoices }, the
    /// original first (purchase.invoices.create).
    /// </summary>
    [HttpPost("{id:int}/split-by-item")]
    [ProducesResponseType<SplitByItemResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SplitByItemResultDto>> SplitByItem(
        int id, [FromBody] SplitByItemRequest? request, CancellationToken cancellationToken)
    {
        var result = await _documents.SplitByItemAsync(
            id, request ?? new SplitByItemRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
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

    /// <summary>
    /// "Post selected" on an order's invoices: body { ids }. Each draft purchase invoice is posted on its own, in
    /// order — a refusal does not stop the others. Answers [{ id, ok, documentNumber, code, message }] (purchase.invoices.post).
    /// </summary>
    [HttpPost("post-many")]
    [ProducesResponseType<IReadOnlyList<BulkActionItemResult>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<IReadOnlyList<BulkActionItemResult>>> PostMany(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
    {
        var result = await _documents.PostManyAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

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

    /// <summary>
    /// Multipart: file, attachmentTypeId (required: a type used for the document's kind - PO, PINV or PRET), and optionally documentDate
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
        var result = await _documents.DeleteFileAsync(id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
