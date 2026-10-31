namespace Inventory_Shipment.Model.DTOs.Inventory.Transfers;

/*
 * (91) FILL TO MAX, ADD ITEMS BELOW MIN, CREATE A TRANSFER ORDER FROM STOCK LEVELS (script 91, prompt 48).
 *
 * ONE RULE, ON THE SERVER (inventory.fn_TransferFill_Plan): per ITEM, in pcs, Need = (To's Max, else its Min) − To's
 * Projected before this order − what the item's other lines already order; rounded UP to whole units of the line's
 * unit; capped at the whole units available at From (on hand − other released orders' To dispatch − the item's other
 * lines). Fill SETS the item's first line, never adds; Add makes a new line per item; a second run changes nothing. The
 * page shows a preview (nothing written), then applies it with the order's RowVersion, which computes it again.
 */

/// <summary>Fill (the order's own lines) or Add (items not on the order, from the drawer).</summary>
public static class TransferFillModes
{
    public const string Fill = "Fill";
    public const string Add = "Add";
}

/// <summary>What the plan says of one line or item (fn_TransferFill_Plan's Outcome).</summary>
public static class TransferFillOutcomes
{
    public const string Filled = "Filled";
    public const string AtOrAboveMin = "AtOrAboveMin";
    public const string NoLevel = "NoLevel";
    public const string Covered = "Covered";
    public const string Inactive = "Inactive";
    public const string NothingAvailable = "NothingAvailable";

    /// <summary>Add mode: the item is already on the order ("on the order: use Fill to Max").</summary>
    public const string OnOrder = "OnOrder";
}

/// <summary>One item ticked in the drawer, in the unit chosen (null = the item's base unit).</summary>
public sealed class TransferFillItemRequest
{
    public int ItemId { get; init; }
    public int? ItemUnitId { get; init; }
}

/// <summary>
/// POST {id}/fill-to-max/preview and {id}/fill-to-max: no <see cref="AddItems"/> = Fill the order's lines; items = Add
/// them as new lines. The apply sends the ORDER's row version (the preview ignores it).
/// </summary>
public sealed class TransferFillRequest
{
    public string? RowVersion { get; init; }
    public IReadOnlyList<TransferFillItemRequest> AddItems { get; init; } = [];
}

public sealed class TransferFillCountsDto
{
    public int Filled { get; init; }

    /// <summary>Filled, but less than needed: From has no more available.</summary>
    public int Capped { get; init; }

    /// <summary>Filled rows whose quantity differs from the line's (Fill) or new lines (Add).</summary>
    public int Changed { get; init; }

    public int AtOrAboveMin { get; init; }
    public int NoLevel { get; init; }
    public int Covered { get; init; }
    public int Inactive { get; init; }
    public int OnOrder { get; init; }

    /// <summary>Nothing available at From.</summary>
    public int NotFilled { get; init; }
}

/// <summary>One line (Fill) or one item (Add) of the plan, in pcs unless named in the line's unit.</summary>
public sealed class TransferFillLineDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public bool ItemIsActive { get; init; }

    /// <summary>The order line Fill sets (the item's first); null in Add mode before the apply.</summary>
    public int? LineId { get; init; }

    /// <summary>The line's number; after an Add apply, the new line's.</summary>
    public int? LineNumber { get; init; }

    public int ItemUnitId { get; init; }
    public string UnitName { get; init; } = string.Empty;

    /// <summary>The unit's CURRENT packing formula (pcs per unit): what the rounding and the apply use.</summary>
    public int PackingFormula { get; init; }

    /// <summary>The line's Ordered now, in its unit and in pcs (its stored OrderedBase); null in Add mode.</summary>
    public int? CurrentQuantity { get; init; }

    public int? CurrentQuantityBase { get; init; }

    /// <summary>What the plan sets, in the line's unit and in pcs; null unless Filled.</summary>
    public int? NewQuantity { get; init; }

    public int? NewQuantityBase { get; init; }

    /// <summary>Ordered on the item's other lines of this order.</summary>
    public int OtherLinesBase { get; init; }

    /// <summary>The item is already on the order (Add mode: it is skipped).</summary>
    public bool OnOrder { get; init; }

    public int ToOnHandBase { get; init; }
    public int ToInOnTheWayBase { get; init; }
    public int ToInToDispatchBase { get; init; }
    public int ToOutToDispatchBase { get; init; }

    /// <summary>To's Projected without this order.</summary>
    public int ToProjectedBeforeBase { get; init; }

    /// <summary>To's Projected with this order as the plan leaves it ("18 → 60").</summary>
    public int ToProjectedAfterBase { get; init; }

    public bool ToHasLevel { get; init; }
    public int? ToMinBase { get; init; }
    public int? ToMaxBase { get; init; }

    /// <summary>(Max, else Min) − Projected before − the other lines; null without a level at To.</summary>
    public int? NeedBase { get; init; }

    public int? UnitsNeeded { get; init; }
    public int? UnitsAvailable { get; init; }
    public int FromOnHandBase { get; init; }

    /// <summary>What the other released orders still take from From.</summary>
    public int FromCommittedBase { get; init; }

    /// <summary>"Available at {From}": on hand − committed, never below 0.</summary>
    public int AvailableFromBase { get; init; }

    /// <summary>Available at From for THIS line: − the item's other lines, never below 0.</summary>
    public int AvailableForLineBase { get; init; }

    /// <summary><see cref="TransferFillOutcomes"/>.</summary>
    public string Outcome { get; init; } = string.Empty;

    public bool IsCapped { get; init; }

    /// <summary>The apply changes (Fill) or adds (Add) this line.</summary>
    public bool IsChanged { get; init; }

    public bool FromHasLevel { get; init; }
    public int? FromMinBase { get; init; }
    public int FromProjectedBeforeBase { get; init; }

    /// <summary>From's Projected after this order as the plan leaves it.</summary>
    public int FromAfterBase { get; init; }

    /// <summary>From goes below its own Min with this order (orange; never a refusal).</summary>
    public bool FromBelowMinAfter { get; init; }

    /// <summary>Preview only: pieces also on purchase orders or in containers for To (not counted, shown dimmed).</summary>
    public int? PurchasesToComeBase { get; init; }
}

/// <summary>The preview (nothing written) or the apply (the order re-read) of Fill to Max / Add items below Min.</summary>
public sealed class TransferFillResult
{
    public bool Applied { get; init; }

    /// <summary><see cref="TransferFillModes"/>.</summary>
    public string Mode { get; init; } = TransferFillModes.Fill;

    /// <summary>The server's sentence: "Fill to Max: 4 lines filled (2 capped by what LKS-01 has available), …".</summary>
    public string Message { get; init; } = string.Empty;

    public TransferFillCountsDto Counts { get; init; } = new();

    /// <summary>In item code order.</summary>
    public IReadOnlyList<TransferFillLineDto> Lines { get; init; } = [];

    /// <summary>From below its own Min; other drafts / waiting orders to the same To with the same items.</summary>
    public IReadOnlyList<string> Warnings { get; init; } = [];

    /// <summary>The order as it now stands, after an apply; null on a preview.</summary>
    public TransferOrderDto? Order { get; init; }
}

/// <summary>GET {id}/below-min: the drawer's filters.</summary>
public sealed class TransferBelowMinQuery
{
    public string? Search { get; init; }
    public int? ItemFamilyId { get; init; }
    public int? BrandId { get; init; }

    /// <summary>Off: every item with a level at To.</summary>
    public bool OnlyBelowMin { get; init; } = true;
}

/// <summary>One item with a level at the order's To (the drawer's row).</summary>
public sealed class TransferBelowMinItemDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? FamilyName { get; init; }
    public string? BrandName { get; init; }
    public int BaseUnitId { get; init; }
    public string BaseUnitName { get; init; } = string.Empty;
    public int ToOnHandBase { get; init; }
    public int ToInOnTheWayBase { get; init; }
    public int ToInToDispatchBase { get; init; }
    public int ToOutToDispatchBase { get; init; }
    public int ToProjectedBeforeBase { get; init; }
    public int? ToMinBase { get; init; }
    public int? ToMaxBase { get; init; }
    public int? NeedBase { get; init; }
    public int AvailableFromBase { get; init; }

    /// <summary>Below To's Min (an item the order already covers is not).</summary>
    public bool IsBelowMin { get; init; }

    public bool OnOrder { get; init; }
    public bool FromHasLevel { get; init; }
    public int? FromMinBase { get; init; }
    public int FromProjectedBeforeBase { get; init; }
}

/// <summary>What the server proposes for one item in one of its units.</summary>
public sealed class TransferBelowMinUnitDto
{
    public int ItemId { get; init; }
    public int ItemUnitId { get; init; }
    public string UnitName { get; init; } = string.Empty;
    public int PackingFormula { get; init; }
    public bool IsBaseUnit { get; init; }

    /// <summary>In the unit ("2 BOX"), and in pcs ("= 24 pcs"); null unless Filled.</summary>
    public int? ProposedQuantity { get; init; }

    public int? ProposedBase { get; init; }
    public bool IsCapped { get; init; }

    /// <summary><see cref="TransferFillOutcomes"/>.</summary>
    public string Outcome { get; init; } = string.Empty;

    public bool FromBelowMinAfter { get; init; }
}

public sealed class TransferBelowMinResult
{
    /// <summary>By Need, largest first, then item code.</summary>
    public IReadOnlyList<TransferBelowMinItemDto> Items { get; init; } = [];

    public IReadOnlyList<TransferBelowMinUnitDto> Units { get; init; } = [];
}

/// <summary>The levels of the order's To, on the order's page (usp_TransferOrder_Get, script 91).</summary>
public sealed class TransferOrderLevelsDto
{
    /// <summary>Levels at To for active items: none disables Fill to Max and Add items below Min with the reason.</summary>
    public int ToLevelCount { get; init; }

    /// <summary>Items still below To's Min after this order (an item on two lines counts once).</summary>
    public int ItemsBelowMin { get; init; }
}

/* ── create a transfer order from Inventory › Stock Levels ────────────────────────────────────── */

/// <summary>POST api/inventory/stock-levels/create-transfer: ticked rows of ONE destination; each item in its base unit.</summary>
public sealed class CreateTransferFromLevelsRequest
{
    public int? FromWarehouseId { get; init; }
    public int? ToWarehouseId { get; init; }
    public IReadOnlyList<int> ItemIds { get; init; } = [];

    /// <summary>Null = today (UTC).</summary>
    public DateOnly? DocumentDate { get; init; }

    public DateOnly? ExpectedArrival { get; init; }
}

public sealed class CreateTransferFromLevelsResult
{
    public int OrderId { get; init; }

    /// <summary>Null when the TRO type numbers at release.</summary>
    public string? DocumentNumber { get; init; }

    /// <summary>"TRO-BR-003-000015 created. Add items below Min: 2 items added (…), 1 not added (…)."</summary>
    public string Message { get; init; } = string.Empty;

    /// <summary>
    /// Fill to Max's warnings for the new draft (3.3.6.3 step 5): "{From} goes below its own Min for {item}: …" and
    /// "Other draft or waiting transfer orders to {To} hold some of these items too (…): Fill to Max does not count them."
    /// </summary>
    public IReadOnlyList<string> Warnings { get; init; } = [];
}
