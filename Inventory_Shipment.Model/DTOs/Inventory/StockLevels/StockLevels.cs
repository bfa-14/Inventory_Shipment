using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory.StockLevels;

/// <summary>
/// Stock levels per warehouse (script 91): an item's Min (required, pcs, 0 or more) and Max (optional, not below Min) in
/// ONE warehouse at the bottom of the tree, never an On the way warehouse (inventory.ItemWarehouseLevels).
///
/// TWO MIN / MAX, NEVER ONE. The item's Minimum / Maximum Quantity of Item Definition stay the COMPANY's (the Dashboard's
/// "Items below their minimum", the company view of Inventory › Stock Levels); these are each warehouse's own, the ones
/// Fill to Max tops a warehouse up to.
///
/// ONE FORMULA (inventory.fn_StockPosition, on top of script 90's fn_TransferPosition): Projected = On hand + On the way
/// in + To come in − To go out, released transfer orders only; drafts, orders waiting for approval and purchases are not
/// counted. The status is the first that applies: no level, Below Min (Projected &lt; Min), Below Min covered (On hand &lt;
/// Min ≤ Projected), Above Max (Projected &gt; Max), OK.
/// </summary>
public static class StockLevelStatuses
{
    public const string BelowMin = "BelowMin";

    /// <summary>"Below Min, covered": on hand is below Min, but transfers on the way or released bring it to Min or more.</summary>
    public const string Covered = "Covered";

    public const string AboveMax = "AboveMax";
    public const string Ok = "Ok";

    /// <summary>A pair (item, warehouse) without a level: only listed when the filter asks for it.</summary>
    public const string NoLevel = "NoLevel";

    /// <summary>The words of the page and the export.</summary>
    public static string Label(string? status) => status switch
    {
        BelowMin => "Below Min",
        Covered => "Below Min, covered",
        AboveMax => "Above Max",
        Ok => "OK",
        NoLevel => "No level",
        _ => status ?? string.Empty,
    };
}

/// <summary>Where a change of a level was made (the audit's Source).</summary>
public static class StockLevelSources
{
    /// <summary>The "Stock levels per warehouse" card of Item Definition (the default).</summary>
    public const string ItemCard = "ItemCard";

    /// <summary>Inventory › Stock Levels.</summary>
    public const string StockLevels = "StockLevels";

    /// <summary>An Excel import, with its file name.</summary>
    public const string Import = "Import";
}

/* ── per warehouse ────────────────────────────────────────────────────────────────────────────── */

/// <summary>GET api/inventory/stock-levels (and its export): inventory.usp_StockLevel_Search's parameters.</summary>
public sealed class StockLevelQuery
{
    /// <summary>Item code or name (contains), or a unit barcode exactly.</summary>
    public string? Search { get; init; }

    public int? BranchId { get; init; }

    /// <summary>That warehouse, or the leaves under it.</summary>
    public int? WarehouseId { get; init; }

    /// <summary>The family and the families under it.</summary>
    public int? ItemFamilyId { get; init; }

    public int? BrandId { get; init; }
    public int? ItemId { get; init; }

    /// <summary>Empty: every level. BelowMin | Covered | AboveMax | Ok; NoLevel lists the pairs without a level.</summary>
    public string? Status { get; init; }

    public bool ActiveItemsOnly { get; init; } = true;
    public bool IncludeInactiveWarehouses { get; init; }
}

/// <summary>One item in one warehouse: its level and where the warehouse stands for it (pcs).</summary>
public sealed class StockLevelRowDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public bool ItemIsActive { get; init; }
    public string? ItemFamilyName { get; init; }
    public string? BrandName { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public bool WarehouseIsActive { get; init; }
    public int BranchId { get; init; }
    public string? BranchCode { get; init; }
    public string? BranchName { get; init; }
    public bool HasLevel { get; init; }
    public int? MinQuantityBase { get; init; }

    /// <summary>Null: no maximum (Fill to Max fills up to Min).</summary>
    public int? MaxQuantityBase { get; init; }

    /// <summary>The ledger balance.</summary>
    public int OnHandBase { get; init; }

    /// <summary>Dispatched to this warehouse by released transfer orders, not received or written off yet.</summary>
    public int InOnTheWayBase { get; init; }

    /// <summary>Still to dispatch TO this warehouse on released transfer orders.</summary>
    public int InToDispatchBase { get; init; }

    /// <summary>Still to dispatch FROM this warehouse on released transfer orders: promised, still on the shelf.</summary>
    public int OutToDispatchBase { get; init; }

    /// <summary>On hand + on the way in + to come in − to go out. May be negative.</summary>
    public int ProjectedBase { get; init; }

    /// <summary>(Max, else Min) − Projected when Below Min, else 0: what Fill to Max would ask for.</summary>
    public int ToReachMaxBase { get; init; }

    /// <summary><see cref="StockLevelStatuses"/>.</summary>
    public string Status { get; init; } = StockLevelStatuses.NoLevel;

    /// <summary>When the level was last changed (null without a level).</summary>
    public DateTime? UpdatedAtUtc { get; init; }

    public string? UpdatedByName { get; init; }

    /// <summary>Base64 ROWVERSION of the level, sent back to change or remove it; null without a level.</summary>
    public string? RowVersion { get; init; }
}

/// <summary>The scope's totals (the status filter ignored, levels only): the page's tiles.</summary>
public sealed class StockLevelTotalsDto
{
    public int Levels { get; init; }
    public int BelowMin { get; init; }
    public int Covered { get; init; }
    public int AboveMax { get; init; }
    public int Ok { get; init; }
}

public sealed class StockLevelListResult
{
    public IReadOnlyList<StockLevelRowDto> Rows { get; init; } = [];
    public StockLevelTotalsDto Totals { get; init; } = new();
}

/* ── the company view (Item Definition's Minimum / Maximum Quantity, the Dashboard's figure) ──────────────────────── */

/// <summary>GET api/inventory/stock-levels/company: inventory.usp_StockLevel_CompanySearch's parameters.</summary>
public sealed class CompanyStockLevelQuery
{
    public string? Search { get; init; }

    /// <summary>Empty: the company (every warehouse, On the way included); a branch: every warehouse of it.</summary>
    public int? BranchId { get; init; }

    public int? ItemFamilyId { get; init; }
    public int? BrandId { get; init; }

    /// <summary>Empty: every item with a company Min or Max. BelowMin | AboveMax | Ok.</summary>
    public string? Status { get; init; }

    public bool ActiveItemsOnly { get; init; } = true;
}

public sealed class CompanyStockLevelRowDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public bool ItemIsActive { get; init; }
    public string? ItemFamilyName { get; init; }
    public string? BrandName { get; init; }

    /// <summary>The stock of every warehouse of the scope (the branch's, or the company's), goods on the way to it included.</summary>
    public int OnHandBase { get; init; }

    /// <summary>Item Definition's Minimum Quantity (the company's).</summary>
    public int MinQuantity { get; init; }

    /// <summary>Item Definition's Maximum Quantity (the company's); null: none.</summary>
    public int? MaxQuantity { get; init; }

    /// <summary>Minimum − on hand when Below Min, else 0.</summary>
    public int MissingBase { get; init; }

    /// <summary>BelowMin | AboveMax | Ok.</summary>
    public string Status { get; init; } = StockLevelStatuses.Ok;

    /// <summary>How many warehouses have their own level for the item ("3 warehouses" opens Per warehouse).</summary>
    public int WarehouseLevelCount { get; init; }
}

public sealed class CompanyStockLevelTotalsDto
{
    public int Items { get; init; }
    public int BelowMin { get; init; }
}

/// <summary>Whose stock the figures are: a branch, or the company when <see cref="BranchId"/> is null.</summary>
public sealed class CompanyStockLevelScopeDto
{
    public int? BranchId { get; init; }
    public string? BranchName { get; init; }
}

public sealed class CompanyStockLevelListResult
{
    public IReadOnlyList<CompanyStockLevelRowDto> Rows { get; init; } = [];
    public CompanyStockLevelTotalsDto Totals { get; init; } = new();
    public CompanyStockLevelScopeDto Scope { get; init; } = new();
}

/* ── set, remove, history ─────────────────────────────────────────────────────────────────────── */

/// <summary>One warehouse's level as sent (inventory.tvp_ItemWarehouseLevel); the RowVersion of a level already read.</summary>
public sealed class SetStockLevelRequest
{
    public int WarehouseId { get; init; }
    public int? MinQuantityBase { get; init; }
    public int? MaxQuantityBase { get; init; }

    /// <summary>Base64 ROWVERSION of the level when it was read (null: a new level, or replace whatever is there).</summary>
    public string? RowVersion { get; init; }
}

/// <summary>PUT api/inventory/stock-levels/items/{itemId}: one item's levels in one or more warehouses, all or nothing.</summary>
public sealed class SetStockLevelsRequest
{
    /// <summary>ItemCard (default) | StockLevels: where the change was made, for the history.</summary>
    [StringLength(20)]
    public string? Source { get; init; }

    public IReadOnlyList<SetStockLevelRequest> Levels { get; init; } = [];
}

public sealed class SetStockLevelsResult
{
    /// <summary>The item's rows again, every warehouse with a level (inactive warehouses and an inactive item included).</summary>
    public IReadOnlyList<StockLevelRowDto> Rows { get; init; } = [];

    /// <summary>"2 stock levels saved for TVS-APACHE-160."</summary>
    public string Message { get; init; } = string.Empty;
}

/// <summary>One change of a level (inventory.ItemWarehouseLevelAudit), newest first.</summary>
public sealed class StockLevelHistoryDto
{
    public long Id { get; init; }
    public DateTime AtUtc { get; init; }
    public string? UserName { get; init; }

    /// <summary>Added | Changed | Removed.</summary>
    public string Action { get; init; } = string.Empty;

    public int? OldMinBase { get; init; }
    public int? OldMaxBase { get; init; }
    public int? NewMinBase { get; init; }
    public int? NewMaxBase { get; init; }

    /// <summary><see cref="StockLevelSources"/>.</summary>
    public string Source { get; init; } = StockLevelSources.ItemCard;

    /// <summary>The imported file's name (Source Import).</summary>
    public string? FileName { get; init; }
}

/* ── the Excel import ─────────────────────────────────────────────────────────────────────────── */

public static class StockLevelImportStatus
{
    public const string Valid = "Valid";
    public const string Warning = "Warning";
    public const string Error = "Error";

    /// <summary>Nothing to change (a row equal to what is stored, Min and Max empty, nothing to remove): skipped.</summary>
    public const string Unchanged = "Unchanged";
}

public static class StockLevelImportActions
{
    public const string Set = "Set";
    public const string Remove = "Remove";

    /// <summary>Every Error and Unchanged row.</summary>
    public const string None = "None";
}

/// <summary>
/// A row as the FILE says it, before any judgement (StockLevelImportParser). A cell that does not read is kept as typed
/// (<see cref="RawMin"/>...) with the sentence in <see cref="ParseError"/>; the database's judgement puts that row in
/// Error first.
/// </summary>
public sealed class StockLevelFileRow
{
    /// <summary>The row of the worksheet, so a message points at what the person sees in Excel.</summary>
    public int RowNumber { get; init; }

    public string? ItemRef { get; init; }
    public string? WarehouseRef { get; init; }
    public int? MinQuantityBase { get; init; }
    public int? MaxQuantityBase { get; init; }
    public bool IsRemove { get; init; }
    public string? RawMin { get; init; }
    public string? RawMax { get; init; }
    public string? RawRemove { get; init; }

    /// <summary>"Min must be a whole number, 0 or more (the file has '2.5')." - the first cell that does not read.</summary>
    public string? ParseError { get; init; }
}

/// <summary>One row of the file with its verdict (inventory.fn_ItemWarehouseLevel_ImportJudge) and what the file had.</summary>
public sealed class StockLevelImportRow
{
    public int RowNumber { get; init; }

    /// <summary><see cref="StockLevelImportStatus"/>.</summary>
    public string Status { get; init; } = StockLevelImportStatus.Error;

    /// <summary><see cref="StockLevelImportActions"/>.</summary>
    public string Action { get; init; } = StockLevelImportActions.None;

    public string? Message { get; init; }

    /// <summary>The Item Code / Barcode cell, as typed (trimmed).</summary>
    [StringLength(100)]
    public string? ItemInput { get; init; }

    public int? ItemId { get; init; }
    public string? ItemCode { get; init; }
    public string? ItemName { get; init; }
    public bool? ItemIsActive { get; init; }

    /// <summary>The Warehouse cell, as typed (trimmed): a code, or a name.</summary>
    [StringLength(150)]
    public string? WarehouseInput { get; init; }

    public int? WarehouseId { get; init; }
    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public string? BranchCode { get; init; }
    public int? MinQuantityBase { get; init; }
    public int? MaxQuantityBase { get; init; }

    /// <summary>The Remove cell is Yes.</summary>
    public bool Remove { get; init; }

    /// <summary>Min / Max / Remove as the file had them when they did not read (null otherwise).</summary>
    public string? RawMin { get; init; }
    public string? RawMax { get; init; }
    public string? RawRemove { get; init; }

    [StringLength(300)]
    public string? ParseError { get; init; }

    /// <summary>The warehouse already has a level for the item: <see cref="CurrentMinBase"/> / <see cref="CurrentMaxBase"/>.</summary>
    public bool HasLevel { get; init; }

    public int? CurrentMinBase { get; init; }
    public int? CurrentMaxBase { get; init; }
}

public sealed class StockLevelImportCounts
{
    /// <summary>Rows that set a level (Valid or Warning).</summary>
    public int Set { get; init; }

    /// <summary>Rows that remove a level (Valid or Warning).</summary>
    public int Remove { get; init; }

    public int Unchanged { get; init; }
    public int Warnings { get; init; }
    public int Errors { get; init; }
}

/// <summary>POST import/validate: every row judged, nothing written.</summary>
public sealed class StockLevelImportValidation
{
    public string FileName { get; init; } = string.Empty;
    public IReadOnlyList<StockLevelImportRow> Rows { get; init; } = [];
    public StockLevelImportCounts Counts { get; init; } = new();
}

/// <summary>POST import: the validated rows posted back; they are judged again, in one transaction.</summary>
public sealed class StockLevelImportRequest
{
    [StringLength(260)]
    public string? FileName { get; init; }

    public IReadOnlyList<StockLevelImportRow> Rows { get; init; } = [];
}

/// <summary>What the import did with one row: Added | Changed | Removed | Unchanged | Skipped (an Error, with its message).</summary>
public sealed class StockLevelImportRowOutcome
{
    public int RowNumber { get; init; }
    public string Outcome { get; init; } = string.Empty;
    public string? Message { get; init; }
}

public sealed class StockLevelImportResult
{
    public int Added { get; init; }
    public int Changed { get; init; }
    public int Removed { get; init; }
    public int Unchanged { get; init; }
    public int Skipped { get; init; }
    public IReadOnlyList<StockLevelImportRowOutcome> Rows { get; init; } = [];

    /// <summary>"Stock levels imported: 40 added, 12 changed, 3 removed; 5 rows without a change and 2 rows with errors skipped."</summary>
    public string Message { get; init; } = string.Empty;
}
