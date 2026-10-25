using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// Goods receipts (GRN): from scripts 64 and 65 on, the only way goods enter stock.
///
/// A RECEIPT IS COUNTED AT THE GATE, NOT BILLED. A supplier invoice makes the amount payable and sets the cost the
/// received goods are valued at; the receipt says what arrived, where it went and when. Its source is a container (a
/// draft made when its Delivery movement is completed, or "Receive goods..." on it), a purchase order, a posted
/// purchase invoice, or none ("Without an order", a supplier required). Draft → Posted → Cancelled, five verbs of
/// their own (purchase.goodsreceipts.*). The refusals are the procedures' sentences, 63xxx: 400 for what the request
/// got wrong, 404 for a receipt that does not exist, 409 for the state of the world.
/// </summary>
[ApiController]
[Route("api/purchase/goods-receipts")]
[Produces("application/json")]
public sealed class GoodsReceiptsController : ControllerBase
{
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IGoodsReceiptService _receipts;

    public GoodsReceiptsController(IGoodsReceiptService receipts)
    {
        _receipts = receipts;
    }

    /// <summary>
    /// The list, paged, with the totals of the whole filter (received and not invoiced yet, in pieces and at the order
    /// price). Filters: search, status, sourceKind, branchId, supplierId, warehouseId, dateFrom, dateTo, containerId,
    /// purchaseOrderId, invoiceId, movementId, isAuto, withDifferences, receivedNotInvoiced, deliveredNotReceived,
    /// notReceived; sortBy / sortDir; page / pageSize.
    /// </summary>
    [HttpGet]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [ProducesResponseType<GoodsReceiptListResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<GoodsReceiptListResult>> Search(
        [FromQuery] GoodsReceiptQuery query, CancellationToken cancellationToken)
    {
        var result = await _receipts.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The draft goods receipts, for the menu count (hidden at 0).</summary>
    [HttpGet("waiting")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [ProducesResponseType<GoodsReceiptWaitingDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<GoodsReceiptWaitingDto>> Waiting(CancellationToken cancellationToken)
    {
        var result = await _receipts.WaitingAsync(User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// When goods receipts started: the date the purchase invoice list's banner names ("Since {date}, posting a
    /// supplier invoice no longer adds stock..."). Any signed-in user: it is shown to the people who post invoices, who
    /// may not see goods receipts. Null before the switch.
    /// </summary>
    [HttpGet("switch")]
    [Authorize]
    [ProducesResponseType<GoodsReceiptSwitchDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<GoodsReceiptSwitchDto>> Switch(CancellationToken cancellationToken)
        => Ok(await _receipts.SwitchAsync(cancellationToken));

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [ProducesResponseType<GoodsReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<GoodsReceiptDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _receipts.GetAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The data of the printable receipt (signed at the gate): the document itself, the page prints it.</summary>
    [HttpGet("{id:int}/print")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [ProducesResponseType<GoodsReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public Task<ActionResult<GoodsReceiptDto>> Print(int id, CancellationToken cancellationToken)
        => GetById(id, cancellationToken);

    /// <summary>A new draft, of any source (sourceKind, or what containerId / purchaseInvoiceId / the lines say).</summary>
    [HttpPost]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<GoodsReceiptDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptDto>> Create(
        [FromBody] GoodsReceiptSaveRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.SaveDraftAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<GoodsReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptDto>> Update(
        int id, [FromBody] GoodsReceiptSaveRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.SaveDraftAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A draft only; rowVersion (base64) refuses it when somebody changed it since.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, [FromQuery] string? rowVersion, CancellationToken cancellationToken)
    {
        var result = await _receipts.DeleteAsync(id, rowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Posts a draft: the goods enter stock. Answers the document, with its number.</summary>
    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsPost)]
    [ProducesResponseType<GoodsReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptDto>> Post(
        int id, [FromBody] GoodsReceiptPostRequest? request, CancellationToken cancellationToken)
    {
        var result = await _receipts.PostAsync(id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// "Post selected": body { ids }. Each draft is posted on its own, in order - a refusal does not stop the others.
    /// Answers [{ id, ok, documentNumber, code, message }].
    /// </summary>
    [HttpPost("post-many")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsPost)]
    [ProducesResponseType<IReadOnlyList<BulkActionItemResult>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<BulkActionItemResult>>> PostMany(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.PostManyAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A posted receipt, with a reason: the stock goes back out (refused when it was used, or its cost adjusted since).</summary>
    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCancel)]
    [ProducesResponseType<GoodsReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptDto>> Cancel(
        int id, [FromBody] GoodsReceiptCancelRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.CancelAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── "Receive goods..." ───────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// What the "Receive goods..." dialogs propose, in pieces: ?purchaseOrderId= (an order's lines), ?invoiceId= (an
    /// invoice's lines not in a container), ?supplierId= (the supplier's posted or closed orders with something to
    /// receive: "+ New › From a purchase order...") or ?containerId= (a container and its lines). Exactly one.
    /// </summary>
    [HttpGet("receivable")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<ReceivableDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ReceivableDto>> Receivable(
        [FromQuery] ReceivableQuery query, CancellationToken cancellationToken)
    {
        var result = await _receipts.ReceivableAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>"+ New › From a container...": the containers Confirmed to Cleared with no receipt (search, branchId, supplierId, deliveredOnly).</summary>
    [HttpGet("receivable-containers")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<IReadOnlyList<ReceivableContainerDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<ReceivableContainerDto>>> ReceivableContainers(
        [FromQuery] ReceivableContainersQuery query, CancellationToken cancellationToken)
    {
        var result = await _receipts.ReceivableContainersAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// A draft from a purchase order: body { purchaseOrderId, documentDate?, supplierReference?, warehouseId?, notes?,
    /// lines?: [{ poLineId, quantityBase, warehouseId?, closeShort, reasonCode?, reason?, expiryDate?, notes? }], post }.
    /// No lines = every line with something to receive. post = posted at once (purchase.goodsreceipts.post too); a
    /// refused posting leaves the draft (postRefusal). Answers { id, documentNumber?, status, ... }.
    /// </summary>
    [HttpPost("from-order")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<GoodsReceiptCreatedDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptCreatedDto>> FromOrder(
        [FromBody] ReceiveFromOrderRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.ReceiveFromOrderAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return CreatedOrProblem(result);
    }

    /// <summary>
    /// A draft from a posted purchase invoice, for its lines not linked to a container: body { invoiceId, documentDate?,
    /// supplierReference?, warehouseId?, notes?, lines?: [{ invoiceLineId, quantityBase, warehouseId?, closeShort,
    /// reasonCode?, reason?, expiryDate?, notes? }], post }. As from-order.
    /// </summary>
    [HttpPost("from-invoice")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<GoodsReceiptCreatedDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptCreatedDto>> FromInvoice(
        [FromBody] ReceiveFromInvoiceRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.ReceiveFromInvoiceAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return CreatedOrProblem(result);
    }

    /// <summary>
    /// "Receive goods..." on a container (Confirmed to Cleared, no receipt yet): body { containerId, documentDate?,
    /// warehouseId?, lines?: [{ containerLineId, quantityBase, varianceReasonCode?, varianceReason?, expiryDate?,
    /// notes? }], post }. No lines = every line as loaded. As from-order.
    /// </summary>
    [HttpPost("from-container")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType<GoodsReceiptCreatedDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<GoodsReceiptCreatedDto>> FromContainer(
        [FromBody] ReceiveContainerRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.ReceiveContainerAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return CreatedOrProblem(result);
    }

    private ActionResult<GoodsReceiptCreatedDto> CreatedOrProblem(Result<GoodsReceiptCreatedDto> result)
        => result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    /// <summary>GRN-{number}.xlsx: the header, and per line expected, received, difference, reason, cost, value and source.</summary>
    [HttpGet("{id:int}/export")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _receipts.ExportAsync(id, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Multipart: file, attachmentTypeId (required: a type used for goods receipts, kind GRN - a delivery note, a damage
    /// report...), and optionally documentDate (yyyy-MM-dd) and note. PDF, image or Office file, up to 20 MB. In any
    /// status: a delivery note may come after the posting.
    /// </summary>
    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
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

        var result = await _receipts.AddFileAsync(
            id, file.FileName, file.ContentType, buffer.ToArray(), fields, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    /// <summary>The files with their type, date and note, newest first; attachmentTypeId = one type only.</summary>
    [HttpGet("{id:int}/files")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [ProducesResponseType<IReadOnlyList<DocumentFileDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<DocumentFileDto>>> ListFiles(
        int id, [FromQuery] int? attachmentTypeId, CancellationToken cancellationToken)
    {
        var result = await _receipts.ListFilesAsync(id, attachmentTypeId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsView)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _receipts.GetFileAsync(id, fileId, User.GetPermissions(), cancellationToken);

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
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
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

        var result = await _receipts.UpdateFileAsync(id, fileId, edit!, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Purchase.GoodsReceiptsCreate)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _receipts.DeleteFileAsync(id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
