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
/// The cash boxes and bank accounts a customer receipt is paid into. Each holds ONE currency. One
/// "manage" permission for the list and the writes; the LOOKUP is open to any signed-in user, because
/// the receipt page picks from it, and takes the line's currency and the receipt's branch so it only
/// offers accounts the line is allowed to use.
/// </summary>
[ApiController]
[Route("api/masterdata/cash-bank-accounts")]
[Produces("application/json")]
public sealed class CashBankAccountsController : ControllerBase
{
    private readonly ICashBankAccountService _accounts;

    public CashBankAccountsController(ICashBankAccountService accounts)
    {
        _accounts = accounts;
    }

    [HttpGet]
    [HasPermission(Permissions.MasterData.CashBankAccountsManage)]
    [ProducesResponseType<PagedResult<CashBankAccountDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<CashBankAccountDto>>> Search([FromQuery] CashBankAccountQuery query, CancellationToken cancellationToken)
    {
        var result = await _accounts.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<CashBankAccountLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<CashBankAccountLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? currencyId = null, [FromQuery] int? branchId = null,
        [FromQuery] int? includeId = null, CancellationToken cancellationToken = default)
    {
        var result = await _accounts.LookupAsync(activeOnly, currencyId, branchId, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.CashBankAccountsManage)]
    [ProducesResponseType<CashBankAccountDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<CashBankAccountDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _accounts.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>A code already in use fails with 409 DUPLICATE_CODE.</summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.CashBankAccountsManage)]
    [ProducesResponseType<CashBankAccountDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CashBankAccountDto>> Create([FromBody] SaveCashBankAccountRequest request, CancellationToken cancellationToken)
    {
        var result = await _accounts.SaveAsync(null, request, User.GetUserId(), User.GetPermissions(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>The currency of an account receipts already use cannot change (400 VALIDATION).</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.CashBankAccountsManage)]
    [ProducesResponseType<CashBankAccountDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CashBankAccountDto>> Update(int id, [FromBody] SaveCashBankAccountRequest request, CancellationToken cancellationToken)
    {
        var result = await _accounts.SaveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deactivating keeps a used account readable on old receipts; deleting is for one nothing has used.</summary>
    [HttpPost("{id:int}/set-active")]
    [HasPermission(Permissions.MasterData.CashBankAccountsManage)]
    [ProducesResponseType<CashBankAccountDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CashBankAccountDto>> SetActive(
        int id, [FromBody] SetReceiptMasterActiveRequest request, CancellationToken cancellationToken)
    {
        var result = await _accounts.SetActiveAsync(id, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>409 IN_USE when receipts use it.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.CashBankAccountsManage)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _accounts.DeleteAsync(id, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
