using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Logistics;

/// <summary>
/// Container charges imported from an Excel file ("Import charges from Excel…" on Logistics › Containers):
/// one row = one charge on one container.
///
/// THE PATTERN OF THE INVOICE IMPORT: the template, a validate that reads the file and judges every row
/// without creating anything, an error report built from the rows the client posts back, and the import of
/// the validated rows the client posts back. The file is never kept on the server: what is imported is what
/// the person was shown.
/// </summary>
[ApiController]
[Route("api/logistics/container-charges/import")]
public sealed class ContainerChargeImportController : ControllerBase
{
    private readonly IContainerChargeImportService _imports;

    public ContainerChargeImportController(IContainerChargeImportService imports)
    {
        _imports = imports;
    }

    /// <summary>"Import_Container_Charges_Template.xlsx": sheets Charges (two example rows), Instructions and Lists.</summary>
    [HttpGet("template")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [Produces(ContainerChargeImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public async Task<IActionResult> GetTemplate(CancellationToken cancellationToken)
    {
        var result = await _imports.GenerateTemplateAsync(User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? File(result.Value.Content, ContainerChargeImportWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Reads the uploaded .xlsx (form field "file") and answers every row with its verdict — Valid, Warning or
    /// Error — and what it resolved to. Nothing is created. "today" (optional, yyyy-MM-dd) is the browser's
    /// date, used for a blank Charge Date.
    ///
    /// A 400 with code INVALID_FILE is the file's own problem (not .xlsx, over 5 MB, more than 5,000 rows, not
    /// the template's columns). A bad ROW is not a failure of the call: it comes back with its own message.
    /// </summary>
    [HttpPost("validate")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType<ContainerChargeImportValidation>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    // Twice the file limit, as the invoice import: a file slightly too big reaches the service and is refused
    // by name (INVALID_FILE), rather than cut off here with a bare 400.
    [RequestSizeLimit(ContainerChargeImportParser.MaxFileBytes * 2)]
    public async Task<ActionResult<ContainerChargeImportValidation>> Validate(
        [FromForm] IFormFile file, [FromForm] DateOnly? today, CancellationToken cancellationToken)
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
            stream, file.FileName, file.Length, today, User.GetPermissions(), cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// The Warning and Error rows posted back (the validate answer's rows, as they came), as a workbook with the
    /// template's columns plus Row, Status and Message: "Import_Container_Charges_Errors.xlsx".
    /// </summary>
    [HttpPost("error-report")]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [Produces(ContainerChargeImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult GetErrorReport([FromBody] IReadOnlyList<ContainerChargeImportValidatedRow> rows)
    {
        var result = _imports.GenerateErrorReport(rows ?? [], User.GetPermissions());

        return result.IsSuccess
            ? File(result.Value.Content, ContainerChargeImportWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Creates the charges of the rows posted back (Error rows skipped): body { post, fileName, rows }. Each row
    /// on its own — 200 with created / posted / failed per row, even when some failed. post = true posts every
    /// charge after creating it and needs containers.charges.post (403 FORBIDDEN before anything is created).
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.Containers.ChargesCreate)]
    [ProducesResponseType<ContainerChargeImportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ContainerChargeImportResult>> Import(
        [FromBody] ContainerChargeImportRequest request, CancellationToken cancellationToken)
    {
        var result = await _imports.ImportAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
