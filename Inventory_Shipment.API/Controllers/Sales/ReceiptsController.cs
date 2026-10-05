using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Sales;

/// <summary>
/// Customer receipts - money coming in, optionally allocated to sales invoices.
///
/// ONE PERMISSION PER ACTION THAT MOVES MONEY. Viewing, drafting, posting, reversing, deleting and
/// allocating are separate rights, because the person who may type a receipt is not necessarily the
/// one who may make it pay an invoice. Each is checked on the action here AND in the service.
///
/// A RECEIPT IS ALWAYS RETURNED WHOLE. Save, post, reverse and allocate answer with the re-read
/// receipt, so the page never has to guess what the procedure did.
/// </summary>
[ApiController]
[Route("api/sales/receipts")]
[Produces("application/json")]
public sealed class ReceiptsController : ControllerBase
{
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".xlsx", ".xls", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    };

    private const long MaxFileBytes = 10 * 1024 * 1024;

    private readonly IReceiptService _receipts;

    public ReceiptsController(IReceiptService receipts)
    {
        _receipts = receipts;
    }

    [HttpGet]
    [HasPermission(Permissions.Sales.ReceiptsView)]
    [ProducesResponseType<PagedResult<ReceiptListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<ReceiptListDto>>> Search([FromQuery] ReceiptQuery query, CancellationToken cancellationToken)
    {
        var result = await _receipts.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The official rate for a currency on a date - what a payment line pre-fills.
    ///
    /// DECLARED BEFORE {id} so "rate" is never read as a receipt id. Rate is null in the answer when
    /// none is defined: an ordinary state the page turns into a warning and an editable box.
    /// </summary>
    [HttpGet("rate")]
    [HasPermission(Permissions.Sales.ReceiptsView)]
    [ProducesResponseType<ReceiptRateDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ReceiptRateDto>> GetRate(
        [FromQuery] int currencyId, [FromQuery] DateOnly? date = null, CancellationToken cancellationToken = default)
    {
        var result = await _receipts.ResolveRateAsync(currencyId, date, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The customer's posted sales invoices with something left to pay, oldest first. Also declared before {id}.</summary>
    [HttpGet("open-invoices")]
    [HasPermission(Permissions.Sales.ReceiptsView)]
    [ProducesResponseType<IReadOnlyList<OpenInvoiceDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<OpenInvoiceDto>>> OpenInvoices(
        [FromQuery] int clientId, CancellationToken cancellationToken)
    {
        var result = await _receipts.OpenInvoicesAsync(clientId, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A customer's account in the base currency, optionally for a period.</summary>
    [HttpGet("statement")]
    [HasPermission(Permissions.Sales.ReceiptsView)]
    [ProducesResponseType<CustomerStatementDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<CustomerStatementDto>> Statement(
        [FromQuery] int clientId, [FromQuery] DateOnly? dateFrom, [FromQuery] DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var result = await _receipts.StatementAsync(clientId, dateFrom, dateTo, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Sales.ReceiptsView)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ReceiptDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _receipts.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a draft. It may be unbalanced - the balance is enforced when it is POSTED, so a half
    /// typed receipt can be kept - but every line must name an account of its own currency.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.Sales.ReceiptsCreate)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ReceiptDto>> Create([FromBody] SaveReceiptRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.SaveDraftAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Edits a draft; lines and allocations are replaced. A posted receipt answers 409 NOT_EDITABLE.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Sales.ReceiptsCreate)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ReceiptDto>> Update(int id, [FromBody] SaveReceiptRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.SaveDraftAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Drafts only. A posted receipt is corrected by reversing it, never deleted.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Sales.ReceiptsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _receipts.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>
    /// Posts a draft. 400 UNBALANCED when the payment lines (or the allocations) do not add up to the
    /// receipt amount; 409 ALLOCATION_EXCEEDS_OUTSTANDING when an invoice was paid since the draft
    /// was saved.
    /// </summary>
    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Sales.ReceiptsPost)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ReceiptDto>> Post(int id, [FromBody] PostReceiptRequest? request, CancellationToken cancellationToken)
    {
        var result = await _receipts.PostAsync(
            id, request ?? new PostReceiptRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Reverses a posted receipt; the invoices it paid owe the money again. A Free Receipt that has
    /// since been applied to invoices answers 409 HAS_ALLOCATIONS until those allocations are removed.
    /// </summary>
    [HttpPost("{id:int}/reverse")]
    [HasPermission(Permissions.Sales.ReceiptsReverse)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ReceiptDto>> Reverse(int id, [FromBody] ReverseReceiptRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.ReverseAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Applies the unapplied credit of a posted Free Receipt to invoices. 409 UNAPPLIED_EXCEEDED when it asks for more than is left.</summary>
    [HttpPost("{id:int}/allocations")]
    [HasPermission(Permissions.Sales.ReceiptsAllocate)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ReceiptDto>> Allocate(int id, [FromBody] AllocateReceiptRequest request, CancellationToken cancellationToken)
    {
        var result = await _receipts.AllocateAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Takes back a later allocation; the row stays, stamped, as proof it happened.</summary>
    [HttpDelete("{id:int}/allocations/{allocationId:int}")]
    [HasPermission(Permissions.Sales.ReceiptsAllocate)]
    [ProducesResponseType<ReceiptDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ReceiptDto>> Deallocate(int id, int allocationId, CancellationToken cancellationToken)
    {
        var result = await _receipts.DeallocateAsync(id, allocationId, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Attaches evidence (a transfer slip, a cheque copy). `attachmentTypeId` is a Receipt type from
    /// the attachment-types lookup with appliesTo=Receipt. A posted receipt still takes files - the
    /// evidence often arrives later - a reversed one does not.
    /// </summary>
    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Sales.ReceiptsCreate)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [RequestSizeLimit(MaxFileBytes * 2)]
    public async Task<IActionResult> AddFile(
        int id, IFormFile file, [FromForm] int? attachmentTypeId, [FromForm] string? note, CancellationToken cancellationToken)
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

        var result = await _receipts.AddFileAsync(
            id, attachmentTypeId, note, file.FileName, file.ContentType, buffer.ToArray(),
            User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    [HttpGet("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Sales.ReceiptsView)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _receipts.GetFileAsync(id, fileId, cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Edits a file's name, type and note; a file sent with them replaces the content, none keeps the
    /// stored one. A reversed receipt answers 409 NOT_EDITABLE.
    /// </summary>
    [HttpPut("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Sales.ReceiptsCreate)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    [RequestSizeLimit(MaxFileBytes * 2)]
    public async Task<IActionResult> UpdateFile(
        int id, int fileId, [FromForm] string? fileName, [FromForm] int? attachmentTypeId, [FromForm] string? note,
        IFormFile? file, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(fileName))
        {
            return Invalid("The file name is required.");
        }

        byte[]? content = null;

        if (file is not null)
        {
            if (file.Length == 0)
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
            content = buffer.ToArray();
        }

        var result = await _receipts.UpdateFileAsync(
            id, fileId, attachmentTypeId, note, fileName.Trim(), file?.ContentType, content,
            User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToNoContentResult(this);
    }

    /// <summary>Drafts and posted receipts: evidence filed by mistake can go. A reversed receipt keeps its files (409 NOT_EDITABLE).</summary>
    [HttpDelete("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Sales.ReceiptsCreate)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _receipts.DeleteFileAsync(id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
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
