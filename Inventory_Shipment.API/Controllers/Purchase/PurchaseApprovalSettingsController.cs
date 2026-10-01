using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>Settings > Purchase approval: whether purchase orders need approval, and who approves them, in the app or by email.</summary>
[ApiController]
[Route("api/purchase/approval-settings")]
[Produces("application/json")]
[HasPermission(Permissions.Purchase.ApprovalManage)]
public sealed class PurchaseApprovalSettingsController : ControllerBase
{
    private readonly IPurchaseApprovalService _approvals;

    public PurchaseApprovalSettingsController(IPurchaseApprovalService approvals)
    {
        _approvals = approvals;
    }

    /// <summary>The rules, and every active user with their approval rights.</summary>
    [HttpGet]
    [ProducesResponseType<ApprovalSettingsDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<ApprovalSettingsDto>> Get(CancellationToken cancellationToken)
    {
        var result = await _approvals.GetSettingsAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Approvers = every user row of the page (both rights false = not an approver). 400 VALIDATION with the
    /// message ("Not a valid email address: x", an approver without an address, nobody ticked...); 409 CONCURRENCY.
    /// </summary>
    [HttpPut]
    [ProducesResponseType<ApprovalSettingsDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ApprovalSettingsDto>> Save([FromBody] SaveApprovalSettingsRequest request, CancellationToken cancellationToken)
    {
        var result = await _approvals.SaveSettingsAsync(request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }
}
