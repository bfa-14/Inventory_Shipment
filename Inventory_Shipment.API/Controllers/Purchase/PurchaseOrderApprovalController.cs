using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// The approval of one purchase order, beside the documents' own routes. The purchase order permissions are
/// the service's to check (view to see and decide, post to send, resend, withdraw and email the supplier);
/// whether this user may approve is SQL's to say: 403 NOT_APPROVER / SELF_APPROVAL with its message.
/// NO TOKEN IS EVER ANSWERED: the personal links exist only in the approvers' emails.
/// </summary>
[ApiController]
[Authorize]
[Route("api/purchase/documents")]
[Produces("application/json")]
public sealed class PurchaseOrderApprovalController : ControllerBase
{
    private readonly IPurchaseApprovalService _approvals;

    public PurchaseOrderApprovalController(IPurchaseApprovalService approvals)
    {
        _approvals = approvals;
    }

    /// <summary>The approval state as the caller sees it, the approvers of this order, and the history.</summary>
    [HttpGet("{id:int}/approval")]
    [ProducesResponseType<PurchaseOrderApprovalDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PurchaseOrderApprovalDto>> Get(int id, CancellationToken cancellationToken)
    {
        var result = await _approvals.GetOrderApprovalAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 EMAIL_LINKS_NOT_SET when the address of the application is not set (nothing is changed); 409 APPROVAL_NOT_NEEDED; 409 NO_APPROVER.</summary>
    [HttpPost("{id:int}/send-for-approval")]
    [ProducesResponseType<ApprovalRequestResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ApprovalRequestResultDto>> SendForApproval(
        int id, [FromBody] ApprovalActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _approvals.SendForApprovalAsync(id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:int}/resend-approval")]
    [ProducesResponseType<ApprovalRequestResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ApprovalRequestResultDto>> Resend(
        int id, [FromBody] ApprovalActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _approvals.ResendAsync(id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Waiting -> draft again; the emailed links stop working.</summary>
    [HttpPost("{id:int}/withdraw-approval")]
    [ProducesResponseType<ApprovalDecisionResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ApprovalDecisionResultDto>> Withdraw(
        int id, [FromBody] WithdrawApprovalRequest? request, CancellationToken cancellationToken)
    {
        var result = await _approvals.WithdrawAsync(id, request ?? new WithdrawApprovalRequest(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Approve in the application (posts the order: number assigned), then the follow-up emails.</summary>
    [HttpPost("{id:int}/approve")]
    [ProducesResponseType<ApprovalDecisionResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ApprovalDecisionResultDto>> Approve(
        int id, [FromBody] ApprovalActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _approvals.ApproveAsync(id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Reject in the application, with a reason (400 without one): the order is a draft again.</summary>
    [HttpPost("{id:int}/reject")]
    [ProducesResponseType<ApprovalDecisionResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<ApprovalDecisionResultDto>> Reject(
        int id, [FromBody] RejectPurchaseOrderRequest request, CancellationToken cancellationToken)
    {
        var result = await _approvals.RejectAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A draft that needs approval, approved at once by an in-app approver (self-approval allowed).</summary>
    [HttpPost("{id:int}/approve-now")]
    [ProducesResponseType<ApprovalDecisionResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<ApprovalDecisionResultDto>> ApproveNow(
        int id, [FromBody] ApprovalActionRequest? request, CancellationToken cancellationToken)
    {
        var result = await _approvals.ApproveNowAsync(id, request?.RowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The supplier email of an approved order (409 otherwise) to the given addresses.</summary>
    [HttpPost("{id:int}/send-to-supplier")]
    [ProducesResponseType<SendToSupplierResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SendToSupplierResultDto>> SendToSupplier(
        int id, [FromBody] SendToSupplierRequest request, CancellationToken cancellationToken)
    {
        var result = await _approvals.SendToSupplierAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// A new purchase order in one call (same body as create): the draft, then the request for approval - or the
    /// posting when approval is not needed. A refused request KEEPS the draft (approvalRequested false, the message).
    /// </summary>
    [HttpPost("create-and-send")]
    [ProducesResponseType<CreateAndSendResultDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<CreateAndSendResultDto>> CreateAndSend(
        [FromBody] SavePurchaseDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _approvals.CreateAndSendAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return Created(result, result.Value?.Id);
    }

    /// <summary>A new purchase order approved directly (or posted when approval is not needed); a refusal keeps the draft.</summary>
    [HttpPost("create-and-approve")]
    [ProducesResponseType<CreateAndApproveResultDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    public async Task<ActionResult<CreateAndApproveResultDto>> CreateAndApprove(
        [FromBody] SavePurchaseDocumentRequest request, CancellationToken cancellationToken)
    {
        var result = await _approvals.CreateAndApproveAsync(request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return Created(result, result.Value?.Id);
    }

    private ActionResult Created<T>(Result<T> result, int? id)
        => result.IsSuccess
            ? base.Created($"/api/purchase/documents/{id}", result.Value)
            : this.ToProblem(result);
}
