using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
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
        [FromQuery] DateOnly? date = null, [FromQuery] int? currencyId = null, CancellationToken cancellationToken = default)
    {
        var result = await _invoices.ResolveRateAsync(priceListId, rateType, date, currencyId, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The specifications already typed for this item on sales lines, newest first — what the line's
    /// Specification box offers. The box is free text; these are only suggestions, so an item nobody
    /// has sold yet answers an empty list rather than an error.
    /// </summary>
    [HttpGet("item-specifications")]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [ProducesResponseType<IReadOnlyList<string>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<string>>> GetItemSpecifications(
        [FromQuery] int itemId, CancellationToken cancellationToken = default)
    {
        var result = await _invoices.ItemSpecificationsAsync(itemId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Sales.InvoicesView)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<SalesInvoiceDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _invoices.GetAsync(id, User.GetPermissions(), cancellationToken);
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

    /// <summary>
    /// The Import Sales page's single call: the header and lines become a draft that is posted at
    /// once. Answers with the posted invoice's summary. A draft that fails to post is deleted, so a
    /// failure here leaves nothing behind — the page keeps its lines, fixes them and calls again.
    ///
    /// GUARDED BY THE POST PERMISSION HERE AND THE CREATE PERMISSION IN THE SERVICE: the two rights
    /// this one call spends. A caller with only the first gets 403.
    /// </summary>
    [HttpPost("import-post")]
    [HasPermission(Permissions.Sales.InvoicesPost)]
    [ProducesResponseType<ImportPostResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ImportPostResult>> ImportPost(
        [FromBody] SaveSalesInvoiceRequest request, CancellationToken cancellationToken)
    {
        var result = await _invoices.ImportPostAsync(
            request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
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
        var result = await _invoices.PostAsync(
            id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken,
            acknowledgeOutOfStock: request?.AcknowledgeOutOfStock ?? false);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// What posting this invoice would run into: every item + warehouse it asks more of than the warehouse holds,
    /// each with the policy's verdict (warehouse override, else the global setting). The page shows the warning
    /// from this BEFORE posting; an empty list means nothing to warn about.
    /// </summary>
    [HttpGet("{id:int}/stock-check")]
    [HasPermission(Permissions.Sales.InvoicesPost)]
    [ProducesResponseType<StockCheckDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<StockCheckDto>> StockCheck(int id, CancellationToken cancellationToken)
    {
        var result = await _invoices.StockCheckAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// A sales return draft from a posted invoice: the remaining quantities, the invoice's prices
    /// and its ORIGINAL cost of sales. There is no returns page yet — the draft and its number come
    /// back so the caller can say what was made.
    /// </summary>
    [HttpPost("{id:int}/create-return")]
    [HasPermission(Permissions.Sales.InvoicesCreate)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SalesInvoiceDto>> CreateReturn(
        int id, [FromBody] CreateSalesReturnRequest? request, CancellationToken cancellationToken)
    {
        var result = await _invoices.CreateReturnAsync(
            id, request?.DocumentDate, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPost("{id:int}/cancel")]
    [HasPermission(Permissions.Sales.InvoicesCancel)]
    [ProducesResponseType<SalesInvoiceDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SalesInvoiceDto>> Cancel(
        int id, [FromBody] CancelSalesInvoiceRequest request, CancellationToken cancellationToken)
    {
        var result = await _invoices.CancelAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
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

    /// <summary>Posts several drafts at once, each in its own transaction; the result says what happened to each.</summary>
    [HttpPost("bulk-post")]
    [HasPermission(Permissions.Sales.InvoicesPost)]
    [ProducesResponseType<BulkActionResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<BulkActionResult>> BulkPost(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
        => Ok(await _invoices.BulkPostAsync(request.Ids, User.GetUserId(), User.GetPermissions(), cancellationToken));

    /// <summary>Deletes several drafts; a posted invoice among them fails alone with NOT_DRAFT.</summary>
    [HttpPost("bulk-delete")]
    [HasPermission(Permissions.Sales.InvoicesDelete)]
    [ProducesResponseType<BulkActionResult>(StatusCodes.Status200OK)]
    public async Task<ActionResult<BulkActionResult>> BulkDelete(
        [FromBody] BulkActionRequest request, CancellationToken cancellationToken)
        => Ok(await _invoices.BulkDeleteAsync(request.Ids, User.GetUserId(), cancellationToken));

    /// <summary>
    /// An imported file becoming ONE invoice holding every line, each in the warehouse it names,
    /// posted at once when asked (which also needs the post permission, checked in the service).
    /// </summary>
    [HttpPost("import-create")]
    [HasPermission(Permissions.Sales.InvoicesCreate)]
    [ProducesResponseType<ImportCreateResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ImportCreateResult>> ImportCreate(
        [FromBody] ImportCreateSalesInvoicesRequest request, CancellationToken cancellationToken)
    {
        var result = await _invoices.ImportCreateAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
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
