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
