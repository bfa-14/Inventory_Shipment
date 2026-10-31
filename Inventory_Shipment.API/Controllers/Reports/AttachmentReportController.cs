using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Reports;

/// <summary>
/// Reports › Attachment Report (script 101): every module's attachments by type and by document and upload dates,
/// paged on the server; one file, several or all downloaded at once.
///
/// The permission opens the report; each file is listed and downloaded only for a reader who may open its document.
/// </summary>
[ApiController]
[Route("api/reports/attachments")]
[Produces("application/json")]
public sealed class AttachmentReportController : ControllerBase
{
    private readonly IAttachmentReportService _reports;

    public AttachmentReportController(IAttachmentReportService reports)
    {
        _reports = reports;
    }

    [HttpGet]
    [HasPermission(Permissions.Reports.AttachmentsView)]
    [ProducesResponseType<AttachmentReportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<AttachmentReportResult>> List(
        [FromQuery] AttachmentReportQuery query, CancellationToken cancellationToken)
    {
        var result = await _reports.ListAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The attachment types the filter offers (inactive ones too: older files keep theirs).</summary>
    [HttpGet("types")]
    [HasPermission(Permissions.Reports.AttachmentsView)]
    [ProducesResponseType<IReadOnlyList<AttachmentReportTypeDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<AttachmentReportTypeDto>>> Types(CancellationToken cancellationToken)
    {
        var result = await _reports.TypesAsync(User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The chosen files (one comes back as itself, several as a ZIP) or, with All, every file matching the filters as a
    /// ZIP. Refused (409, code TOO_LARGE) above the configured number of files or bytes.
    /// </summary>
    [HttpPost("download")]
    [HasPermission(Permissions.Reports.AttachmentsView)]
    [Produces("application/octet-stream")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Download([FromBody] AttachmentDownloadRequest request, CancellationToken cancellationToken)
    {
        var result = await _reports.DownloadAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        // File() disposes the stream once it is sent, which deletes the temporary file.
        return result is { IsSuccess: true, Value: { } file }
            ? File(file.Content, file.ContentType, file.FileName)
            : this.ToProblem(result);
    }
}
