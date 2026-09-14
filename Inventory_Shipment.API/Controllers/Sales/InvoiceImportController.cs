using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Sales;

/// <summary>
/// Importing invoice lines from an Excel file.
///
/// AN ENGINE, NOT A PAGE. Nothing here creates or changes an invoice: the endpoints hand out the
/// template, say what a file contains, hand back a report of what was wrong with it, and record that
/// an import happened. The lines themselves go to whichever screen asked — today a sandbox, tomorrow
/// the Sales Invoice page — and are saved by that screen with the rest of the invoice.
///
/// THE FILE IS READ ON EVERY VALIDATE AND NEVER KEPT. There is no server-side session holding "the
/// last upload": the client posts the file, gets the judged rows, and owns them from there. A person
/// who leaves the wizard open for an hour and then presses Import gets exactly the rows they were
/// shown, and nothing on the server had to remember them.
/// </summary>
[ApiController]
[Route("api/sales/invoice-import")]
public sealed class InvoiceImportController : ControllerBase
{
    private readonly IInvoiceImportService _imports;

    public InvoiceImportController(IInvoiceImportService imports)
    {
        _imports = imports;
    }

    /// <summary>
    /// The blank import template for one document type — the SAME workbook for every type, its
    /// "Document Type" column pre-filled with the requested code and every type listed in the
    /// instructions. File name "Import_INV_IN_Template.xlsx".
    /// </summary>
    [HttpGet("template")]
    [HasPermission(Permissions.Sales.InvoicesImport)]
    [Produces(InvoiceImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetTemplate(
        [FromQuery][Required] string documentTypeCode, CancellationToken cancellationToken)
    {
        var result = await _imports.GenerateTemplateAsync(documentTypeCode, cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, InvoiceImportWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Reads an uploaded .xlsx and judges every row against the master data of the chosen branch,
    /// warehouse and price list.
    ///
    /// PRICE LIST OPTIONAL. With one, rows are priced against it and a row with no price is an
    /// error; without one (stock mode) nothing is priced and the Unit Price column is the unit cost.
    ///
    /// STOCK IS CHECKED ONLY WHEN ASKED (checkStock=true): the Import Sales page asks, because its
    /// rows are about to leave the warehouse; a stock-in import does not. Either way each row carries
    /// onHandBase and requiredBase, so a preview can show the shelf beside the demand.
    ///
    /// A 400 WITH code INVALID_FILE is the file's own problem — not .xlsx, over 10 MB, or without the
    /// template's columns. A 400 with MASTER_INACTIVE is the HEADER's: the branch, the default
    /// warehouse or the price list is missing or inactive, or the warehouse is not in the branch.
    /// Rows that are individually wrong are NOT failures of this call: they come back with their own
    /// status and message, which is the whole point of validating before importing.
    /// </summary>
    [HttpPost("validate")]
    [HasPermission(Permissions.Sales.InvoicesImport)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType<ImportValidationResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    /*
     * DELIBERATELY LOOSER THAN THE 10 MB THE FEATURE ALLOWS, and the gap is the whole point.
     *
     * A request cut off by this attribute never reaches the action, so it answers with a bare 400 and
     * no problem details — the client gets a number where it expected code INVALID_FILE and a sentence
     * saying the file is too big. Set at twice the limit, an 11 or 15 MB upload (which is what "too
     * big" actually looks like: somebody's real file, slightly over) reaches the service and is
     * refused properly, by name.
     *
     * The ceiling still exists, because the alternative is buffering half a gigabyte to say no.
     */
    [RequestSizeLimit(InvoiceImportParser.MaxFileBytes * 2)]
    public async Task<ActionResult<ImportValidationResult>> Validate(
        [FromForm] IFormFile file,
        [FromForm] int branchId,
        [FromForm] int warehouseId,
        // OPTIONAL, AND ITS ABSENCE MEANS SOMETHING. Omitted, the import runs in stock mode for an
        // Inventory In / Out document: no price list, no pricing checks, and the Unit Price column
        // read as the unit cost. A nullable form field is how "not sent" stays distinguishable from 0.
        [FromForm] int? priceListId,
        // OFF BY DEFAULT. On, a row that would take more than the stock on hand — cumulatively with
        // the rows above it for the same item and warehouse — is an Error, and every row carries the
        // on-hand and required figures. The Import Sales page turns it on; a stock-in import must not.
        [FromForm] bool checkStock = false,
        // REQUIRED FROM NOW ON: the page's own type. It decides the unit a blank Unit cell means and
        // rejects rows whose "Document Type" cell names another type.
        [FromForm][Required] string documentTypeCode = "",
        CancellationToken cancellationToken = default)
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

        var result = await _imports.ValidateAsync(
            stream,
            file.FileName,
            file.Length,
            branchId,
            warehouseId,
            priceListId,
            checkStock,
            documentTypeCode,
            // FROM THE TOKEN, never from the request: whether a manual price in the file is honoured
            // is a permission, and a client that could ask for it would not need to hold it.
            User.GetPermissions(),
            cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// The non-valid rows of a validated file, as a workbook to correct and re-upload.
    ///
    /// THE ROWS ARE POSTED BACK rather than looked up. Nothing on the server kept them (see the class
    /// remark), and asking the client for what it is already showing is what keeps that true: no
    /// upload cache, no expiry, and the report can only ever describe the rows the person is looking
    /// at.
    /// </summary>
    [HttpPost("error-report")]
    [HasPermission(Permissions.Sales.InvoicesImport)]
    [Produces(InvoiceImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult GetErrorReport([FromBody] IReadOnlyList<InvoiceImportValidatedRow> rows)
        => File(
            _imports.GenerateErrorReport(rows ?? []),
            InvoiceImportWorkbooks.ContentType,
            InvoiceImportWorkbooks.ErrorReportFileName);

    /// <summary>
    /// Records that an import happened: the file, the counts, and the draft the lines went into.
    ///
    /// WRITTEN WHEN THE LINES ARE TAKEN, not when the file is validated. Somebody may validate five
    /// files and import one; logging every validation would make the audit trail a record of people
    /// looking at spreadsheets. The draft reference is what lets the invoice, saved later, claim this
    /// row (usp_InvoiceImport_AttachInvoice).
    /// </summary>
    [HttpPost("log")]
    [HasPermission(Permissions.Sales.InvoicesImport)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> Log(
        [FromBody] InvoiceImportLogRequest request, CancellationToken cancellationToken)
    {
        var result = await _imports.LogAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? Ok(new { id = result.Value })
            : this.ToProblem(result);
    }
}
