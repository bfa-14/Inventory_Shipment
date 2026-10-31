using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// Stock levels per warehouse (script 91): each warehouse's own Min / Max of an item (pcs, a warehouse at the bottom of
/// the tree), where it stands - on hand, what released transfer orders bring and take, Projected - and the company view
/// of Item Definition's Minimum / Maximum Quantity (the Dashboard's figure).
///
/// VIEW READS, EDIT CHANGES (inventory.stocklevels.view / .edit). The refusals are the procedures' sentences: 400 for what
/// the request got wrong, 404 for a level that no longer exists, 409 for one changed or removed by another user. The
/// Excel import follows the other imports: template, validate (nothing written), error report, import of the rows posted
/// back (judged again, one transaction). "Create transfer order…" is the transfer service's (its codes).
/// </summary>
[ApiController]
[Route("api/inventory/stock-levels")]
[Authorize]
[Produces("application/json")]
public sealed class StockLevelsController : ControllerBase
{
    private readonly IStockLevelService _levels;
    private readonly IStockLevelImportService _imports;
    private readonly ITransferOrderService _transfers;

    public StockLevelsController(IStockLevelService levels, IStockLevelImportService imports, ITransferOrderService transfers)
    {
        _levels = levels;
        _imports = imports;
        _transfers = transfers;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Per warehouse: search (item code or name, or a unit barcode), branchId, warehouseId (that warehouse or the leaves
    /// under it), itemFamilyId (its subtree), brandId, itemId, status (empty: every level; BelowMin, Covered, AboveMax, Ok;
    /// NoLevel: the pairs without a level that hold stock or are on a released transfer), activeItemsOnly (true),
    /// includeInactiveWarehouses (false). The totals are the scope's, the status filter left out.
    /// </summary>
    [HttpGet]
    [HasPermission(Permissions.Inventory.StockLevelsView)]
    [ProducesResponseType<StockLevelListResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<StockLevelListResult>> Search(
        [FromQuery] StockLevelQuery query, CancellationToken cancellationToken)
    {
        var result = await _levels.SearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// "Company (Item Definition)": the items with a company Minimum or Maximum Quantity against the stock of every
    /// warehouse of branchId, or of the company (goods on the way included) - the Dashboard's "Items below their minimum".
    /// status: empty, BelowMin, AboveMax or Ok.
    /// </summary>
    [HttpGet("company")]
    [HasPermission(Permissions.Inventory.StockLevelsView)]
    [ProducesResponseType<CompanyStockLevelListResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<CompanyStockLevelListResult>> Company(
        [FromQuery] CompanyStockLevelQuery query, CancellationToken cancellationToken)
    {
        var result = await _levels.CompanySearchAsync(query, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Every change of one item's level in one warehouse (Added / Changed / Removed, old and new, who, from where), newest first.</summary>
    [HttpGet("items/{itemId:int}/warehouses/{warehouseId:int}/history")]
    [HasPermission(Permissions.Inventory.StockLevelsView)]
    [ProducesResponseType<IReadOnlyList<StockLevelHistoryDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<StockLevelHistoryDto>>> History(
        int itemId, int warehouseId, CancellationToken cancellationToken)
    {
        var result = await _levels.HistoryAsync(itemId, warehouseId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Stock_Levels.xlsx of the list's query: the import's five columns, then information the import ignores.</summary>
    [HttpGet("export")]
    [HasPermission(Permissions.Inventory.StockLevelsView)]
    [Produces(StockLevelImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> Export([FromQuery] StockLevelQuery query, CancellationToken cancellationToken)
    {
        var result = await _levels.ExportAsync(query, User.GetPermissions(), cancellationToken);
        return result.IsSuccess
            ? File(result.Value.Content, StockLevelImportWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /* ── one item's levels ────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Sets one item's Min / Max in one or more warehouses, all or nothing (body { source, levels: [{ warehouseId,
    /// minQuantityBase, maxQuantityBase, rowVersion }] }); a warehouse twice is refused. Answers the item's rows again.
    /// </summary>
    [HttpPut("items/{itemId:int}")]
    [HasPermission(Permissions.Inventory.StockLevelsEdit)]
    [ProducesResponseType<SetStockLevelsResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SetStockLevelsResult>> Set(
        int itemId, [FromBody] SetStockLevelsRequest request, CancellationToken cancellationToken)
    {
        var result = await _levels.SetAsync(itemId, request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Removes one level (an inactive warehouse's too): ?rowVersion= (base64, the level's) &amp;source= (ItemCard | StockLevels).</summary>
    [HttpDelete("items/{itemId:int}/warehouses/{warehouseId:int}")]
    [HasPermission(Permissions.Inventory.StockLevelsEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Remove(
        int itemId, int warehouseId, [FromQuery] string? rowVersion, [FromQuery] string? source, CancellationToken cancellationToken)
    {
        var result = await _levels.RemoveAsync(
            itemId, warehouseId, rowVersion, source, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /* ── the Excel import ─────────────────────────────────────────────────────────────────────── */

    /// <summary>Import_Stock_Levels_Template.xlsx: sheets Levels, Instructions and Example.</summary>
    [HttpGet("import/template")]
    [HasPermission(Permissions.Inventory.StockLevelsEdit)]
    [Produces(StockLevelImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult ImportTemplate()
    {
        var result = _imports.GenerateTemplate(User.GetPermissions());
        return result.IsSuccess
            ? File(result.Value.Content, StockLevelImportWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// Multipart: file (.xlsx, up to 5 MB and 20,000 rows). Every row judged - Valid, Warning, Error or Unchanged, with
    /// its action (Set, Remove, None) and message - and nothing written. 400 INVALID_FILE is the file's own problem.
    /// </summary>
    [HttpPost("import/validate")]
    [HasPermission(Permissions.Inventory.StockLevelsEdit)]
    [Consumes("multipart/form-data")]
    [ProducesResponseType<StockLevelImportValidation>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    // Twice the file limit, as the other imports: a file slightly too big reaches the service and is refused by name.
    [RequestSizeLimit(StockLevelImportParser.MaxFileBytes * 2)]
    public async Task<ActionResult<StockLevelImportValidation>> ImportValidate(
        [FromForm] IFormFile? file, CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(new ProblemDetails
            {
                Status = StatusCodes.Status400BadRequest,
                Title = "Validation failed",
                Detail = "No file was uploaded.",
                Instance = HttpContext.Request.Path,
                Extensions = { ["code"] = "INVALID_FILE" },
            });
        }

        await using var stream = file.OpenReadStream();
        var result = await _imports.ValidateAsync(
            stream, file.FileName, file.Length, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>The Warning and Error rows posted back (the validate answer's rows): Import_Stock_Levels_Errors.xlsx.</summary>
    [HttpPost("import/error-report")]
    [HasPermission(Permissions.Inventory.StockLevelsEdit)]
    [Produces(StockLevelImportWorkbooks.ContentType)]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult ImportErrorReport([FromBody] IReadOnlyList<StockLevelImportRow>? rows)
    {
        var result = _imports.GenerateErrorReport(rows ?? [], User.GetPermissions());
        return result.IsSuccess
            ? File(result.Value.Content, StockLevelImportWorkbooks.ContentType, result.Value.FileName)
            : this.ToProblem(result);
    }

    /// <summary>
    /// The validated rows posted back (body { fileName, rows }): judged again, every Valid and Warning row written in ONE
    /// transaction, Error and Unchanged rows skipped. Answers the outcome of each row, the counts and the sentence.
    /// </summary>
    [HttpPost("import")]
    [HasPermission(Permissions.Inventory.StockLevelsEdit)]
    [ProducesResponseType<StockLevelImportResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    // 20,000 rows posted back are about 12 MB of JSON: room above the server's default 30 MB for long cells.
    [RequestSizeLimit(StockLevelImportParser.MaxFileBytes * 8)]
    public async Task<ActionResult<StockLevelImportResult>> Import(
        [FromBody] StockLevelImportRequest request, CancellationToken cancellationToken)
    {
        var result = await _imports.ImportAsync(request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /* ── a transfer order from the ticked rows ────────────────────────────────────────────────── */

    /// <summary>
    /// "Create transfer order…": ticked rows of ONE destination become one draft from fromWarehouseId, each item filled to
    /// its Max (else Min) in its base unit, capped at what From has available. Nothing available: nothing is created and
    /// the sentence says why (62009). Needs Create Transfer Orders AND View Stock Levels (the two attributes add up).
    /// </summary>
    [HttpPost("create-transfer")]
    [HasPermission(Permissions.Inventory.TransfersCreate)]
    [HasPermission(Permissions.Inventory.StockLevelsView)]
    [ProducesResponseType<CreateTransferFromLevelsResult>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CreateTransferFromLevelsResult>> CreateTransfer(
        [FromBody] CreateTransferFromLevelsRequest request, CancellationToken cancellationToken)
    {
        var result = await _transfers.CreateFromLevelsAsync(request ?? new(), User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.IsSuccess
            ? Created($"/api/inventory/transfers/{result.Value!.OrderId}", result.Value)
            : this.ToProblem(result);
    }
}
