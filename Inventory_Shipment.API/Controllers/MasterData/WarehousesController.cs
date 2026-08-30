using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.MasterData;

/// <summary>Warehouses. Every warehouse belongs to a branch / site; inventory is tracked per warehouse.</summary>
[ApiController]
[Route("api/masterdata/warehouses")]
[Produces("application/json")]
public sealed class WarehousesController : ControllerBase
{
    private readonly IWarehouseService _warehouseService;

    public WarehousesController(IWarehouseService warehouseService)
    {
        _warehouseService = warehouseService;
    }

    /// <summary>Paged, filtered and sorted list of warehouses.</summary>
    [HttpGet]
    [HasPermission(Permissions.MasterData.WarehousesView)]
    [ProducesResponseType<PagedResult<WarehouseDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<WarehouseDto>>> Search(
        [FromQuery] WarehouseQuery query, CancellationToken cancellationToken)
    {
        var result = await _warehouseService.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Warehouses for a dropdown. Any signed-in user may read it: forms all over the application offer a
    /// warehouse to pick, not only the users who administer warehouses.
    /// </summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<WarehouseLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<WarehouseLookupDto>>> Lookup(
        [FromQuery] bool activeOnly = true, [FromQuery] int? branchId = null, [FromQuery] int? includeId = null,
        CancellationToken cancellationToken = default)
    {
        var result = await _warehouseService.LookupAsync(activeOnly, branchId, includeId, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The warehouse currently designated as the Main Warehouse.</summary>
    [HttpGet("main")]
    [HasPermission(Permissions.MasterData.WarehousesView)]
    [ProducesResponseType<WarehouseDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<WarehouseDto>> GetMain(CancellationToken cancellationToken)
    {
        var result = await _warehouseService.GetMainAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.MasterData.WarehousesView)]
    [ProducesResponseType<WarehouseDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<WarehouseDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _warehouseService.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Creates a warehouse. Marking it as the Main Warehouse while another one holds the flag fails with
    /// code MAIN_WAREHOUSE_EXISTS; resend with replaceMainWarehouse = true once the user confirms.
    /// </summary>
    [HttpPost]
    [HasPermission(Permissions.MasterData.WarehousesCreate)]
    [ProducesResponseType<WarehouseDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<WarehouseDto>> Create(
        [FromBody] SaveWarehouseRequest request, CancellationToken cancellationToken)
    {
        var result = await _warehouseService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates a warehouse. Send the rowVersion read with it to detect concurrent edits.</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.MasterData.WarehousesEdit)]
    [ProducesResponseType<WarehouseDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<WarehouseDto>> Update(
        int id, [FromBody] SaveWarehouseRequest request, CancellationToken cancellationToken)
    {
        var result = await _warehouseService.UpdateAsync(id, request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Activates or deactivates a warehouse. The Main Warehouse cannot be deactivated.</summary>
    [HttpPatch("{id:int}/status")]
    [HasPermission(Permissions.MasterData.WarehousesEdit)]
    [ProducesResponseType<WarehouseDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<WarehouseDto>> SetStatus(
        int id, [FromBody] SetWarehouseStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _warehouseService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Deletes a warehouse that holds no inventory. The Main Warehouse cannot be deleted.</summary>
    [HttpDelete("{id:int}")]
    [HasPermission(Permissions.MasterData.WarehousesDelete)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Delete(int id, CancellationToken cancellationToken)
    {
        var result = await _warehouseService.DeleteAsync(id, cancellationToken);
        return result.ToNoContentResult(this);
    }
}
