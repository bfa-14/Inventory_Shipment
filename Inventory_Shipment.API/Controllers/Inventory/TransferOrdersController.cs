using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// Transfer orders (script 90): stock moved from one warehouse to another, of any branch, without changing its cost.
///
/// ONE ORDER, ITS POSTINGS. The order (TRO) is a document with a draft, a release and, when Configuration › Document
/// Types asks for it, an approval; its dispatches (TRD) and transfer receipts (TRR) are posted directly from its page and
/// reversed in place, never drafted. Every action answers the whole order again, re-read, with each action's answer for
/// this reader (abilities), so the page never patches its copy.
///
/// TEN VERBS (inventory.transfers.*), one per action here, two on "Dispatch and receive". The refusals are the
/// procedures' sentences: 400 for what the request got wrong, 403 for an approval by a non-approver, 404 for an order
/// (or a posting of it) that does not exist, 409 for the state of the world.
/// </summary>
[ApiController]
[Route("api/inventory/transfers")]
[Authorize]
[Produces("application/json")]
public sealed partial class TransferOrdersController : ControllerBase
{
    private readonly ITransferOrderService _transfers;

    public TransferOrdersController(ITransferOrderService transfers)
    {
        _transfers = transfers;
    }

    /* ── the list ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The list, paged, with the totals of the whole filter (orders, pieces on the way, late orders, waiting for
    /// approval). Filters: search, status (a shown status or Open), branchId (From's or To's), fromWarehouseId,
    /// toWarehouseId, onTheWayOnly, lateOnly, waitingForApproval, dateFrom, dateTo, itemId; sortColumn / sortDirection;
    /// page / pageSize (at most 200).
    /// </summary>
    [HttpGet]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [ProducesResponseType<TransferOrderListResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<TransferOrderListResult>> Search(
        [FromQuery] TransferOrderQuery query, CancellationToken cancellationToken)
    {
        var result = await _transfers.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The orders waiting for approval, for the approvers' menu count (0 for a reader who may not approve).</summary>
    [HttpGet("waiting")]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [ProducesResponseType<TransferWaitingDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<TransferWaitingDto>> Waiting(CancellationToken cancellationToken)
    {
        var result = await _transfers.WaitingAsync(User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Where items stand at From and at To for the lines of a draft: ?fromWarehouseId=&amp;toWarehouseId=&amp;itemIds=1,2,3
    /// &amp;excludeOrderId= (the draft being edited). Information only: nothing is reserved.
    /// </summary>
    [HttpGet("availability")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<IReadOnlyList<TransferAvailabilityDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<TransferAvailabilityDto>>> Availability(
        [FromQuery] TransferAvailabilityQuery query, CancellationToken cancellationToken)
    {
        var result = await _transfers.AvailabilityAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── one order ────────────────────────────────────────────────────────────────────────────── */

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [ProducesResponseType<TransferOrderDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<TransferOrderDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _transfers.GetAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A new draft, lines and all (they may be empty). Its number is given now unless the TRO type numbers at release.</summary>
    [HttpPost]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferOrderDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferOrderDto>> Create(
        [FromBody] SaveTransferOrderRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return CreatedOrProblem(result);
    }

    /// <summary>Replaces a draft, lines and all. rowVersion (base64) refuses it when somebody changed it since.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferOrderDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferOrderDto>> Update(
        int id, [FromBody] SaveTransferOrderRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>"Save details" once the order is no longer a draft: Expected arrival, Reference No. and Notes (rule T9).</summary>
    [HttpPut("{id:int}/details")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferOrderDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferOrderDto>> UpdateDetails(
        int id, [FromBody] UpdateTransferDetailsRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.UpdateDetailsAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A draft only; its number leaves a gap.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Inventory.TransfersDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, [FromQuery] string? rowVersion, CancellationToken cancellationToken)
    {
        var result = await _transfers.DeleteAsync(id, rowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /* ── release and approval ─────────────────────────────────────────────────────────────────── */

    /// <summary>Releases a draft (warnings: the released orders from From that need more than it holds; nothing is reserved).</summary>
    [HttpPost("{id:int}/release")]
    [HasPermission(Permissions.Inventory.TransfersRelease)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> Release(
        int id, [FromBody] TransferRowVersionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _transfers.ReleaseAsync(id, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Sends a draft for approval; the approvers are emailed (emailWarning when they could not be).</summary>
    [HttpPost("{id:int}/send-for-approval")]
    [HasPermission(Permissions.Inventory.TransfersRelease)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> SendForApproval(
        int id, [FromBody] TransferRowVersionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _transfers.SendForApprovalAsync(id, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Approves a waiting order, or approves and releases a draft ("Approve &amp; release"): released either way.</summary>
    [HttpPost("{id:int}/approve")]
    [HasPermission(Permissions.Inventory.TransfersApprove)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> Approve(
        int id, [FromBody] TransferRowVersionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _transfers.ApproveAsync(id, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Rejects a waiting order with a reason: back to draft, the requester emailed.</summary>
    [HttpPost("{id:int}/reject")]
    [HasPermission(Permissions.Inventory.TransfersApprove)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> Reject(
        int id, [FromBody] TransferReasonRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.RejectAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The requester takes a waiting order back to draft.</summary>
    [HttpPost("{id:int}/withdraw")]
    [HasPermission(Permissions.Inventory.TransfersRelease)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> Withdraw(
        int id, [FromBody] TransferRowVersionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _transfers.WithdrawAsync(id, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A released order with no posting at all (reversed or not) back to draft, with a reason.</summary>
    [HttpPost("{id:int}/back-to-draft")]
    [HasPermission(Permissions.Inventory.TransfersRelease)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> BackToDraft(
        int id, [FromBody] TransferReasonRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.BackToDraftAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── dispatch and receipt ─────────────────────────────────────────────────────────────────── */

    /// <summary>A dispatch (TRD): the pieces leave From for the On the way warehouse of To's branch. An ETA is required.</summary>
    [HttpPost("{id:int}/dispatch")]
    [HasPermission(Permissions.Inventory.TransfersDispatch)]
    [ProducesResponseType<TransferPostedResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferPostedResult>> Dispatch(
        int id, [FromBody] DispatchTransferRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.DispatchAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A transfer receipt (TRR): the pieces arrive into To from the dispatches on the way; "Nothing more will arrive" writes the rest off.</summary>
    [HttpPost("{id:int}/receive")]
    [HasPermission(Permissions.Inventory.TransfersReceive)]
    [ProducesResponseType<TransferPostedResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferPostedResult>> Receive(
        int id, [FromBody] ReceiveTransferRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.ReceiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// "Dispatch and receive": a dispatch and its receipt on one date, in one transaction (both or neither); eta is
    /// ignored. BOTH permissions are required (the two attributes add up).
    /// </summary>
    [HttpPost("{id:int}/dispatch-and-receive")]
    [HasPermission(Permissions.Inventory.TransfersDispatch)]
    [HasPermission(Permissions.Inventory.TransfersReceive)]
    [ProducesResponseType<TransferPostedResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferPostedResult>> DispatchAndReceive(
        int id, [FromBody] DispatchTransferRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.DispatchAndReceiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── close, cancel, reverse, ETA, return ──────────────────────────────────────────────────── */

    /// <summary>"Nothing more will be sent": what is left to dispatch becomes Not sent; goods on the way can still be received.</summary>
    [HttpPost("{id:int}/nothing-more-sent")]
    [HasPermission(Permissions.Inventory.TransfersClose)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> NothingMoreSent(
        int id, [FromBody] TransferReasonRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.NothingMoreSentAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>"Cancel order": a released order with nothing dispatched; no stock moves, the number is kept.</summary>
    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Inventory.TransfersCancel)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> Cancel(
        int id, [FromBody] TransferReasonRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.CancelAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Reverses one whole dispatch or receipt in place (a receipt before its dispatch): rowVersion is the ORDER's.</summary>
    [HttpPost("{id:int}/postings/{postingId:int}/reverse")]
    [HasPermission(Permissions.Inventory.TransfersReverse)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> ReversePosting(
        int id, int postingId, [FromBody] ReverseTransferPostingRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.ReversePostingAsync(id, postingId, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>"Change ETA…" of a dispatch with goods on the way: rowVersion is the ORDER's.</summary>
    [HttpPost("{id:int}/postings/{postingId:int}/eta")]
    [HasPermission(Permissions.Inventory.TransfersDispatch)]
    [ProducesResponseType<TransferActionResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferActionResult>> ChangeEta(
        int id, int postingId, [FromBody] ChangeTransferEtaRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.ChangeEtaAsync(id, postingId, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A new draft from To back to From with what was received and no earlier return takes back (201: open it).</summary>
    [HttpPost("{id:int}/create-return")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType<TransferOrderDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<TransferOrderDto>> CreateReturn(int id, CancellationToken cancellationToken)
    {
        var result = await _transfers.CreateReturnAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return CreatedOrProblem(result);
    }

    /* ── import and export ────────────────────────────────────────────────────────────────────── */

    /// <summary>Transfer_Order_Lines_Template.xlsx: sheet Lines (Item Code / Barcode, Unit, Quantity, Notes) and Instructions.</summary>
    [HttpGet("import-template")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [Produces(TransferOrderWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult ImportTemplate()
    {
        var result = _transfers.ImportTemplate(User.GetPermissions());
        return result.IsSuccess
            ? File(result.Value.Content, TransferOrderWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Multipart: file (.xlsx, up to 10 MB) and fromWarehouseId (the order's From). Every row is judged as the document
    /// import judges it (the base unit by default, a box barcode takes the box, a row naming another type is an Error),
    /// plus a transfer's own refusals: a Warehouse or a Unit Price on a row. Nothing is saved: the page appends the Valid
    /// and Warning rows. 400 INVALID_FILE is the file's own problem; the rows' problems are in the rows.
    /// </summary>
    [HttpPost("import-validate")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType<ImportValidationResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    // Twice the feature's limit, as the document import: an 11 MB file reaches the service and is refused by name.
    [RequestSizeLimit(InvoiceImportParser.MaxFileBytes * 2)]
    public async Task<ActionResult<ImportValidationResult>> ImportValidate(
        [FromForm] IFormFile? file, [FromForm] int? fromWarehouseId, CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(new ProblemDetails
            {
                Status = StatusCodes.Status400BadRequest,
                Title = "Validation failed",
                Detail = "No file was uploaded.",
                Instance = HttpContext.Request.Path,
                Extensions = { ["code"] = "INVALID_FILE" },
            });
        }

        await using var stream = file.OpenReadStream();
        var result = await _transfers.ValidateImportAsync(
            stream, file.FileName, file.Length, fromWarehouseId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>TRO-{number}.xlsx: sheets Order, Lines and "Dispatches and receipts" (values only with View Stock Valuation).</summary>
    [HttpGet("{id:int}/export")]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [Produces(TransferOrderWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _transfers.ExportAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.IsSuccess
            ? File(result.Value.Content, TransferOrderWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Multipart: file, attachmentTypeId (required: a type used for transfer orders, kind TRO - a waybill, a damage
    /// report...), and optionally documentDate (yyyy-MM-dd) and note. PDF, image or Office file, up to 20 MB. In any status.
    /// </summary>
    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
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

        var result = await _transfers.AddFileAsync(
            id, file.FileName, file.ContentType, buffer.ToArray(), fields, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    /// <summary>The files with their type, date and note, newest first; attachmentTypeId = one type only.</summary>
    [HttpGet("{id:int}/files")]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [ProducesResponseType<IReadOnlyList<DocumentFileDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<DocumentFileDto>>> ListFiles(
        int id, [FromQuery] int? attachmentTypeId, CancellationToken cancellationToken)
    {
        var result = await _transfers.ListFilesAsync(id, attachmentTypeId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _transfers.GetFileAsync(id, fileId, User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Multipart: fileName (required), attachmentTypeId (required, as for the upload), and optionally documentDate
    /// (yyyy-MM-dd), note and a file that replaces the stored one (none keeps it). Answers the file's row.
    /// </summary>
    [HttpPut("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
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

        var result = await _transfers.UpdateFileAsync(id, fileId, edit!, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _transfers.DeleteFileAsync(id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    private ActionResult<TransferOrderDto> CreatedOrProblem(Result<TransferOrderDto> result)
        => result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
}
