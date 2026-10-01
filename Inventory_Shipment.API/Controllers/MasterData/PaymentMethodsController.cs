using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>
/// Payment methods (Cash, Bank Transfer, Cheque...) a customer receipt line is paid by. One "manage"
/// permission for the list and the writes; the LOOKUP is open to any signed-in user, because the
/// receipt page picks from it.
/// </summary>
[ApiController]
[Route("api/masterdata/payment-methods")]
[Produces("application/json")]
public sealed class PaymentMethodsController : ControllerBase
{
    private readonly IPaymentMethodService _paymentMethods;

    public PaymentMethodsController(IPaymentMethodService paymentMethods)
    {
        _paymentMethods = paymentMethods;
    }

    [HttpGet]
    [HasPermission(Permissions.MasterData.PaymentMethodsManage)]
    [ProducesResponseType<PagedResult<PaymentMethodDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<PaymentMethodDto>>> Search([FromQuery] PaymentMethodQuery query, CancellationToken cancellationToken)
    {
        var result = await _paymentMethods.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<PaymentMethodLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<PaymentMethodLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _paymentMethods.LookupAsync(activeOnly, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.PaymentMethodsManage)]
    [ProducesResponseType<PaymentMethodDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<PaymentMethodDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _paymentMethods.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A code already in use fails with 409 DUPLICATE_CODE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.PaymentMethodsManage)]
    [ProducesResponseType<PaymentMethodDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentMethodDto>> Create([FromBody] SavePaymentMethodRequest request, CancellationToken cancellationToken)
    {
        var result = await _paymentMethods.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.PaymentMethodsManage)]
    [ProducesResponseType<PaymentMethodDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentMethodDto>> Update(int id, [FromBody] SavePaymentMethodRequest request, CancellationToken cancellationToken)
    {
        var result = await _paymentMethods.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps a used row readable on old receipts; deleting is for one nothing has used.</summary>
    [HttpPost("{id:int}/set-active")]
    [HasPermission(Permissions.MasterData.PaymentMethodsManage)]
    [ProducesResponseType<PaymentMethodDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<PaymentMethodDto>> SetActive(
        int id, [FromBody] SetReceiptMasterActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _paymentMethods.SetActiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 IN_USE when receipts use it.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.PaymentMethodsManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _paymentMethods.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
