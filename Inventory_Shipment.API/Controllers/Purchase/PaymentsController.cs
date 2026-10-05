using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// Supplier payments (US-PAY-001) - money going out to a supplier or service provider, optionally
/// allocated to purchase invoices or to container charges.
///
/// ONE PERMISSION PER ACTION THAT MOVES MONEY: viewing, drafting, posting, reversing, deleting and
/// allocating are separate rights, checked on the action here AND in the service.
///
/// A PAYMENT IS ALWAYS RETURNED WHOLE. Save, post, reverse, allocate and the cheque status answer with
/// the re-read payment, so the page never has to guess what the procedure did.
/// </summary>
[ApiController]
[Route("api/purchase/payments")]
[Produces("application/json")]
public sealed class PaymentsController : ControllerBase
{
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".xlsx", ".xls", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    };

    private const long MaxFileBytes = 10 * 1024 * 1024;

    private readonly IPaymentService _payments;

    public PaymentsController(IPaymentService payments)
    {
        _payments = payments;
    }

    [HttpGet]
    [HasPermission(Permissions.Purchase.PaymentsView)]
    [ProducesResponseType<PagedResult<PaymentListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<PaymentListDto>>> Search([FromQuery] PaymentQuery query, CancellationToken cancellationToken)
    {
        var result = await _payments.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The multiplier from a currency to the payment currency on a date - what a line or allocation
    /// pre-fills. DECLARED BEFORE {id}. RateToPayment is null when a rate is missing: a warning, not an error.
    /// </summary>
    [HttpGet("rate")]
    [HasPermission(Permissions.Purchase.PaymentsView)]
    [ProducesResponseType<PaymentRateDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PaymentRateDto>> GetRate(
        [FromQuery] int fromCurrencyId, [FromQuery] int paymentCurrencyId, [FromQuery] decimal? paymentRate = null,
        [FromQuery] DateOnly? date = null, CancellationToken cancellationToken = default)
    {
        var result = await _payments.RateToPaymentAsync(fromCurrencyId, paymentCurrencyId, paymentRate, date, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The payee's posted purchase invoices (kind=PINV) or container charges (kind=CHARGE) with something
    /// left to pay, oldest first; fully paid ones never appear. Given the payment's currency (and rate and
    /// date), each row carries the rate it pre-fills. Also declared before {id}.
    /// </summary>
    [HttpGet("open-documents")]
    [HasPermission(Permissions.Purchase.PaymentsView)]
    [ProducesResponseType<IReadOnlyList<OpenPayableDocumentDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<IReadOnlyList<OpenPayableDocumentDto>>> OpenDocuments(
        [FromQuery] int payeeId, [FromQuery] string kind, [FromQuery] int? paymentCurrencyId = null,
        [FromQuery] decimal? paymentRate = null, [FromQuery] DateOnly? date = null, CancellationToken cancellationToken = default)
    {
        var result = await _payments.OpenDocumentsAsync(payeeId, kind, paymentCurrencyId, paymentRate, date, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Purchase.PaymentsView)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PaymentDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _payments.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a draft. It may be unbalanced - the balance is enforced when it is POSTED, so a half-typed
    /// payment can be kept - but every line must name an account of its own currency.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.Purchase.PaymentsCreate)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> Create([FromBody] SavePaymentRequest request, CancellationToken cancellationToken)
    {
        var result = await _payments.SaveDraftAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Edits a draft; lines and allocations are replaced. A posted payment answers 409 NOT_EDITABLE.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Purchase.PaymentsCreate)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> Update(int id, [FromBody] SavePaymentRequest request, CancellationToken cancellationToken)
    {
        var result = await _payments.SaveDraftAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Drafts only. A posted payment is corrected by reversing it, never deleted.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Purchase.PaymentsDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _payments.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>
    /// Posts a draft. 400 UNBALANCED when the payment lines (or the allocations) do not add up to the
    /// Payment Amount in the payment currency; 409 ALLOCATION_EXCEEDS_OUTSTANDING when a document was paid
    /// since the draft was saved.
    /// </summary>
    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Purchase.PaymentsPost)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> Post(int id, [FromBody] PostPaymentRequest? request, CancellationToken cancellationToken)
    {
        var result = await _payments.PostAsync(id, request ?? new PostPaymentRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Reverses a posted payment; the documents it paid owe the money again. A Free Payment that has since
    /// been applied answers 409 HAS_ALLOCATIONS until those allocations are removed.
    /// </summary>
    [HttpPost("{id:int}/reverse")]
    [HasPermission(Permissions.Purchase.PaymentsReverse)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> Reverse(int id, [FromBody] ReversePaymentRequest request, CancellationToken cancellationToken)
    {
        var result = await _payments.ReverseAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Applies the advance of a posted Free Payment to invoices OR charges. 409 UNAPPLIED_EXCEEDED when it asks for more than is left.</summary>
    [HttpPost("{id:int}/allocations")]
    [HasPermission(Permissions.Purchase.PaymentsAllocate)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> Allocate(int id, [FromBody] AllocatePaymentRequest request, CancellationToken cancellationToken)
    {
        var result = await _payments.AllocateAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Takes back a later allocation; the row stays, stamped, as proof it happened.</summary>
    [HttpDelete("{id:int}/allocations/{allocationId:int}")]
    [HasPermission(Permissions.Purchase.PaymentsAllocate)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> Deallocate(int id, int allocationId, CancellationToken cancellationToken)
    {
        var result = await _payments.DeallocateAsync(id, allocationId, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Pending / Cleared / Returned on a cheque line of a posted payment. It moves no money.</summary>
    [HttpPost("{id:int}/lines/{lineId:int}/cheque-status")]
    [HasPermission(Permissions.Purchase.PaymentsPost)]
    [ProducesResponseType<PaymentDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentDto>> SetChequeStatus(
        int id, int lineId, [FromBody] SetChequeStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _payments.SetChequeStatusAsync(id, lineId, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Attaches evidence (a SWIFT copy, a cheque copy, a voucher). `attachmentTypeId` is a Payment type from
    /// the attachment-types lookup with appliesTo=Payment. A posted payment still takes files; a reversed one does not.
    /// </summary>
    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Purchase.PaymentsCreate)]
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

        var result = await _payments.AddFileAsync(
            id, attachmentTypeId, note, file.FileName, file.ContentType, buffer.ToArray(),
            User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    [HttpGet("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Purchase.PaymentsView)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _payments.GetFileAsync(id, fileId, cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Edits a file's name, type and note; a file sent with them replaces the content, none keeps the
    /// stored one. A reversed payment answers 409 NOT_EDITABLE.
    /// </summary>
    [HttpPut("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Purchase.PaymentsCreate)]
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

        var result = await _payments.UpdateFileAsync(
            id, fileId, attachmentTypeId, note, fileName.Trim(), file?.ContentType, content,
            User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToNoContentResult(this);
    }

    /// <summary>Drafts and posted payments: evidence filed by mistake can go. A reversed payment keeps its files (409 NOT_EDITABLE).</summary>
    [HttpDelete("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Purchase.PaymentsCreate)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _payments.DeleteFileAsync(id, fileId, User.GetUserId(), User.GetPermissions(), cancellationToken);
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
