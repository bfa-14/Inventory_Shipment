using Inventory_Shipment.Model.Common;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Extensions;

/// <summary>Maps service <see cref="Result"/>s to HTTP responses (RFC 9457 problem details on failure).</summary>
public static class ResultExtensions
{
    public static ActionResult<T> ToActionResult<T>(this Result<T> result, ControllerBase controller)
        => result.IsSuccess ? controller.Ok(result.Value) : controller.ToProblem(result);

    public static ActionResult ToNoContentResult(this Result result, ControllerBase controller)
        => result.IsSuccess ? controller.NoContent() : controller.ToProblem(result);

    public static ActionResult ToProblem(this ControllerBase controller, Result result)
    {
        var (status, title) = result.ErrorType switch
        {
            ErrorType.Validation => (StatusCodes.Status400BadRequest, "Validation failed"),
            ErrorType.Unauthorized => (StatusCodes.Status401Unauthorized, "Unauthorized"),
            ErrorType.Forbidden => (StatusCodes.Status403Forbidden, "Forbidden"),
            ErrorType.NotFound => (StatusCodes.Status404NotFound, "Not found"),
            ErrorType.Conflict => (StatusCodes.Status409Conflict, "Conflict"),
            ErrorType.Locked => (StatusCodes.Status423Locked, "Account locked"),
            ErrorType.Gone => (StatusCodes.Status410Gone, "No longer available"),
            _ => (StatusCodes.Status400BadRequest, "Request failed")
        };

        var problem = new ProblemDetails
        {
            Status = status,
            Title = title,
            Detail = result.Error,
            // The path of a public approval link holds its token: never echoed back.
            Instance = JsonInputErrors.SafePath(controller.HttpContext.Request.Path)
        };

        if (result.Errors.Count > 0)
        {
            problem.Extensions["errors"] = result.Errors;
        }

        if (!string.IsNullOrEmpty(result.Code))
        {
            problem.Extensions["code"] = result.Code;
        }

        if (result.Data is not null)
        {
            problem.Extensions["data"] = result.Data;
        }

        return new ObjectResult(problem) { StatusCode = status };
    }
}
