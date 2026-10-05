using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Purchase;

/// <summary>
/// The containers of a purchase invoice "shipped in containers" (script 43): what it needs, what is linked, and the
/// links made, undone and completed from the invoice.
///
/// THE CONTAINERS ARE THE ORDER'S. "Add container" and "Auto-plan" create them on the invoice's order with the order's
/// own procedures, then link them to the invoice in the same transaction. Linking needs the invoice edit permission;
/// adding containers also containers.create (checked by the service).
/// </summary>
[ApiController]
[Route("api/purchase/documents/{id:int}/containers")]
[Produces("application/json")]
public sealed class PurchaseInvoiceContainersController : ControllerBase
{
    private readonly IPurchaseInvoiceContainerService _containers;

    public PurchaseInvoiceContainersController(IPurchaseInvoiceContainerService containers)
    {
        _containers = containers;
    }

    /// <summary>
    /// Per item: invoiced, pieces per container, containers needed, linked, not linked; the linked containers; and the
    /// state (script 51): canAddContainers / reason, canTurnOnShipped, the figures of the add, canLink / linkReason. Any
    /// purchase invoice answers 200 - the rules are in the state, never a 409.
    /// </summary>
    [HttpGet]
    [HasPermission(Permissions.Purchase.InvoicesView)]
    [ProducesResponseType<InvoiceContainerSummaryDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<InvoiceContainerSummaryDto>> Get(int id, CancellationToken cancellationToken)
    {
        var result = await _containers.GetSummaryAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The container lines the invoice can be linked to (its order's, Draft or Confirmed, not fully invoiced).</summary>
    [HttpGet("candidates")]
    [HasPermission(Permissions.Purchase.InvoicesView)]
    [ProducesResponseType<IReadOnlyList<InvoiceLinkCandidateDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<InvoiceLinkCandidateDto>>> Candidates(int id, CancellationToken cancellationToken)
    {
        var result = await _containers.GetCandidatesAsync(id, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("link")]
    [HasPermission(Permissions.Purchase.InvoicesCreate)]
    [ProducesResponseType<InvoiceContainerSummaryDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<InvoiceContainerSummaryDto>> Link(
        int id, [FromBody] LinkInvoiceContainersRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.LinkAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The invoice's pieces on that container go back to "not in a container yet" (Draft or Confirmed only).</summary>
    [HttpDelete("{containerId:int}")]
    [HasPermission(Permissions.Purchase.InvoicesCreate)]
    [ProducesResponseType<InvoiceContainerSummaryDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<InvoiceContainerSummaryDto>> Unlink(
        int id, int containerId, [FromQuery] string? rowVersion, CancellationToken cancellationToken)
    {
        var result = await _containers.UnlinkAsync(id, containerId, rowVersion, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A container on the invoice's order with the given pieces of the invoice, linked to it.</summary>
    [HttpPost("add")]
    [HasPermission(Permissions.Purchase.InvoicesCreate)]
    [ProducesResponseType<InvoiceContainersCreatedDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<InvoiceContainersCreatedDto>> Add(
        int id, [FromBody] AddInvoiceContainerRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.AddContainerAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The order's auto-plan proposal for the invoice's pieces outside containers. Nothing is saved.</summary>
    [HttpPost("auto-plan")]
    [HasPermission(Permissions.Purchase.InvoicesCreate)]
    [ProducesResponseType<AutoPlanDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<AutoPlanDto>> AutoPlan(
        int id, [FromBody] InvoiceAutoPlanRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.AutoPlanAsync(id, request, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The proposal created on the invoice's order and linked to the invoice, in one transaction.</summary>
    [HttpPost("auto-plan/create")]
    [HasPermission(Permissions.Purchase.InvoicesCreate)]
    [ProducesResponseType<InvoiceContainersCreatedDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<InvoiceContainersCreatedDto>> CreateFromPlan(
        int id, [FromBody] InvoiceContainersFromPlanRequest request, CancellationToken cancellationToken)
    {
        var result = await _containers.CreateFromPlanAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
