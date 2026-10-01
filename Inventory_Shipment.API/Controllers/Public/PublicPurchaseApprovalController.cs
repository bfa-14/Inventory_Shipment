using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace Inventory_Shipment.API.Controllers.Public;

/// <summary>
/// The approval page of an emailed link - NO SIGN-IN: the token is the approver's proof. 30 requests a minute
/// per address (429 beyond). Reading never decides: only the POST of the page's button does.
/// 410 LINK_NOT_USABLE with what happened to the link, 403 NOT_APPROVER / SELF_APPROVAL.
/// </summary>
[ApiController]
[AllowAnonymous]
[EnableRateLimiting(AuthenticationExtensions.PublicApprovalRateLimitPolicy)]
[Route("api/public/purchase-approval")]
[Produces("application/json")]
public sealed class PublicPurchaseApprovalController : ControllerBase
{
    private readonly IPurchaseApprovalService _approvals;

    public PublicPurchaseApprovalController(IPurchaseApprovalService approvals)
    {
        _approvals = approvals;
    }

    /// <summary>The order, its lines, the approver and until when the link is valid. "action" (approve | reject) is the page's, and ignored here.</summary>
    [HttpGet("{token}")]
    [ProducesResponseType<PublicApprovalDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status410Gone)]
    public async Task<ActionResult<PublicApprovalDto>> Get(string token, [FromQuery] string? action, CancellationToken cancellationToken)
    {
        _ = action;
        var result = await _approvals.GetPublicAsync(token, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Approve (posts the order) or reject (a reason is required), once.</summary>
    [HttpPost("{token}/decision")]
    [ProducesResponseType<PublicDecisionResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status410Gone)]
    public async Task<ActionResult<PublicDecisionResultDto>> Decide(
        string token, [FromBody] PublicDecisionRequest request, CancellationToken cancellationToken)
    {
        var result = await _approvals.DecidePublicAsync(token, request, cancellationToken);
        return result.ToActionResult(this);
    }
}
