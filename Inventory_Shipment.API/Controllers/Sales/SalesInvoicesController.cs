using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Sales;

/// <summary>
/// Sales invoices — the second document family, on the skeleton the stock documents established.
///
/// [HasPermission] IS BACK ON THE ACTIONS. The stock documents controller could not use it because
/// one route served two kinds with two permission sets; this one serves the invoice alone, so the
/// house pattern applies without a detour through the service.
///
/// A DOCUMENT IS ALWAYS RETURNED WHOLE. Save, post and cancel answer with the re-read invoice:
/// posting assigns the number, writes the ledger, snapshots the cost of goods and moves the status,
/// and a client that had to guess which of those happened would be reimplementing the procedure.
/// </summary>
[ApiController]
[Route("api/sales/invoices")]
[Produces("application/json")]
public sealed class SalesInvoicesController : ControllerBase
{
    private static readonly HashSet<string> AllowedFileTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".xlsx", ".xls", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    };

    private const long MaxFileBytes = 10 * 1024 * 1024;
    private const string SpreadsheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly ISalesInvoiceService _invoices;

    public SalesInvoicesController(ISalesInvoiceService invoices)
    {
        _invoices = invoices;
    }

    [HttpGet]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [ProducesResponseType<PagedResult<SalesInvoiceListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<SalesInvoiceListDto>>> Search(
        [FromQuery] SalesInvoiceQuery query, CancellationToken cancellationToken)
    {
        var result = await _invoices.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The exchange rate for a price list's currency on a date — what the page pre-fills.
    ///
    /// DECLARED BEFORE {id} so "rate" is never read as an invoice id. Rate is null in the answer when
    /// none is defined: that is an ordinary state the page turns into a warning and an editable box,
    /// not a failure of this call.
    /// </summary>
    [HttpGet("rate")]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [ProducesResponseType<RateResolutionDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<RateResolutionDto>> GetRate(
        [FromQuery] int priceListId, [FromQuery] byte rateType = RateTypes.Official,
        [FromQuery] DateOnly? date = null, CancellationToken cancellationToken = default)
    {
        var result = await _invoices.ResolveRateAsync(priceListId, rateType, date, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<SalesInvoiceDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _invoices.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a draft. Lines are priced by the procedure from the price list; a manual price is kept
    /// only for a caller holding sales.invoices.priceoverride, which is read from the token here.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.Sales.InvoicesCreate)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<SalesInvoiceDto>> Create(
        [FromBody] SaveSalesInvoiceRequest request, CancellationToken cancellationToken)
    {
        var result = await _invoices.SaveDraftAsync(
            null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Replaces a draft, lines and all. A posted invoice is refused with NOT_DRAFT.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Sales.InvoicesCreate)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SalesInvoiceDto>> Update(
        int id, [FromBody] SaveSalesInvoiceRequest request, CancellationToken cancellationToken)
    {
        var result = await _invoices.SaveDraftAsync(
            id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// Posts a draft: stock leaves the warehouses, the cost of goods is snapshotted, the number is
    /// assigned and the invoice becomes read-only. Refused with INSUFFICIENT_STOCK when a line asks
    /// for more than there is, with the procedure's own figures.
    /// </summary>
    [HttpPost("{id:int}/post")]
    [HasPermission(Permissions.Sales.InvoicesPost)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SalesInvoiceDto>> Post(
        int id, [FromBody] PostSalesInvoiceRequest? request, CancellationToken cancellationToken)
    {
        var result = await _invoices.PostAsync(id, request?.RowVersion, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Sales.InvoicesCancel)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SalesInvoiceDto>> Cancel(
        int id, [FromBody] CancelSalesInvoiceRequest request, CancellationToken cancellationToken)
    {
        var result = await _invoices.CancelAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.Sales.InvoicesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _invoices.DeleteAsync(id, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    [HttpGet("{id:int}/export")]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [Produces(SpreadsheetContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> Export(int id, CancellationToken cancellationToken)
    {
        var result = await _invoices.ExportAsync(id, cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, SpreadsheetContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    [HttpPost("{id:int}/files")]
    [HasPermission(Permissions.Sales.InvoicesCreate)]
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

        var result = await _invoices.AddFileAsync(
            id, file.FileName, file.ContentType, buffer.ToArray(), User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? StatusCode(StatusCodes.Status201Created, new { id = result.Value })
            : this.ToProblem(result);
    }

    [HttpGet("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _invoices.GetFileAsync(id, fileId, cancellationToken);

        return result.IsSuccess
            ? File(result.Value!.Content, result.Value.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    [HttpDelete("{id:int}/files/{fileId:int}")]
    [HasPermission(Permissions.Sales.InvoicesCreate)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<ActionResult> DeleteFile(int id, int fileId, CancellationToken cancellationToken)
    {
        var result = await _invoices.DeleteFileAsync(id, fileId, User.GetUserId(), cancellationToken);
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
