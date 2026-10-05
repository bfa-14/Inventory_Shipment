using Inventory_Shipment.Model.DTOs.Documents;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Extensions;

/// <summary>
/// The checks of every attachment upload and edit (<see cref="AttachmentRules"/>), answered the same way by every
/// controller: 400 INVALID_FILE for a file that may not be attached, 400 VALIDATION for a missing type or a note too
/// long. The procedures check the type again (used for the document's kind, active) with the module's own number.
/// </summary>
public static class AttachmentRequests
{
    /// <summary>The refusal of an upload, or null when the file and its fields may go on.</summary>
    public static IActionResult? RefuseUpload(this ControllerBase controller, IFormFile? file, DocumentFileFields fields)
    {
        var fileError = AttachmentRules.CheckFile(file?.FileName, file?.Length ?? 0);
        return fileError is not null ? Refuse(controller, fileError, "INVALID_FILE") : controller.RefuseFields(fields);
    }

    /// <summary>The refusal of the type / date / note of a file, or null.</summary>
    public static ActionResult? RefuseFields(this ControllerBase controller, DocumentFileFields fields)
    {
        var error = AttachmentRules.CheckFields(fields);
        return error is null ? null : Refuse(controller, error, "VALIDATION");
    }

    /// <summary>
    /// The form of an edit (PUT .../files/{fileId}) read into a <see cref="DocumentFileEdit"/>: the name (required), the
    /// type / date / note, and optionally a new version of the file with the upload's checks. Or the refusal.
    /// </summary>
    public static async Task<(DocumentFileEdit? Edit, ActionResult? Refusal)> ReadEditAsync(
        this ControllerBase controller, string? fileName, DocumentFileFields fields, IFormFile? file,
        CancellationToken cancellationToken)
    {
        var name = Path.GetFileName(fileName?.Trim() ?? string.Empty);
        if (name.Length == 0)
        {
            return (null, Refuse(controller, "The file name is required.", "VALIDATION"));
        }

        if (name.Length > AttachmentRules.FileNameMaxLength)
        {
            return (null, Refuse(
                controller, $"The file name is longer than {AttachmentRules.FileNameMaxLength} characters.", "VALIDATION"));
        }

        if (file is not null && AttachmentRules.CheckFile(file.FileName, file.Length) is { } fileError)
        {
            return (null, Refuse(controller, fileError, "INVALID_FILE"));
        }

        if (controller.RefuseFields(fields) is { } refusal)
        {
            return (null, refusal);
        }

        byte[]? content = null;
        if (file is not null)
        {
            using var buffer = new MemoryStream();
            await file.CopyToAsync(buffer, cancellationToken);
            content = buffer.ToArray();
        }

        return (new DocumentFileEdit { FileName = name, Fields = fields, ContentType = file?.ContentType, Content = content }, null);
    }

    private static BadRequestObjectResult Refuse(ControllerBase controller, string detail, string code)
        => controller.BadRequest(new ProblemDetails
        {
            Status = StatusCodes.Status400BadRequest,
            Title = "Validation failed",
            Detail = detail,
            Instance = controller.HttpContext.Request.Path,
            Extensions = { ["code"] = code },
        });
}
