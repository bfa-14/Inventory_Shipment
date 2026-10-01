using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// What purchase approval means for the signed-in user: the rules, their rights, and the orders waiting for
/// them. Open to every signed-in user - the answer is about the caller only.
/// </summary>
[ApiController]
[Authorize]
[Route("api/purchase/approvals")]
[Produces("application/json")]
public sealed class PurchaseApprovalsController : ControllerBase
{
    private readonly IPurchaseApprovalService _approvals;

    public PurchaseApprovalsController(IPurchaseApprovalService approvals)
    {
        _approvals = approvals;
    }

    /// <summary>The rules, the caller's rights and how many orders wait for them (the menu badge).</summary>
    [HttpGet("me")]
    [ProducesResponseType<ApprovalMeDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<ApprovalMeDto>> Me(CancellationToken cancellationToken)
    {
        var result = await _approvals.GetMeAsync(User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The orders waiting that the caller can approve in the app, oldest first.</summary>
    [HttpGet("pending")]
    [ProducesResponseType<IReadOnlyList<PendingApprovalDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<PendingApprovalDto>>> Pending(CancellationToken cancellationToken)
    {
        var result = await _approvals.GetPendingAsync(User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }
}
