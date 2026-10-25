namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// (92) THE SHARED EARLY CHECK OF WAREHOUSE ACCESS: may this user move stock in these warehouses. The rule and its
/// sentence are the database's (security.fn_User_WarehouseRefusal, "You have no access to warehouse LKS-01: ask an
/// administrator."); the ledger trigger refuses the same rows whatever path writes them, so this check only says it
/// earlier, before a draft is saved or a posting is tried. No cache (M8): every call asks the database - one primary-key
/// seek for a user with All warehouses.
/// </summary>
public interface IWarehouseAccessService
{
    /// <summary>
    /// Null when the user may use every warehouse named; else the database's sentence (security.fn_User_WarehouseRefusal).
    /// Nulls and repeats are ignored; no id at all is never refused (and asks nothing).
    /// </summary>
    Task<string?> RefusalAsync(int userId, IEnumerable<int?> warehouseIds, CancellationToken cancellationToken = default);

    /// <summary>
    /// The same, but the ids are produced only for a restricted user (one primary-key seek for the others): for checks
    /// that would otherwise read the stored document.
    /// </summary>
    Task<string?> RefusalAsync(int userId, Func<Task<IEnumerable<int?>>> warehouseIds, CancellationToken cancellationToken = default);

    /// <summary>
    /// (92) SAVING A DRAFT (A8, line by line): null when the user may save <paramref name="requested"/>; else the
    /// database's sentence for the warehouses at fault. A warehouse the user may use is free. In one they may NOT use:
    /// <list type="bullet">
    /// <item>a line may stay exactly as it is stored (an administrator's draft is corrected line by line; posting it is
    /// refused until it is changed);</item>
    /// <item>a stored line may leave it for one of the user's warehouses (moved: a line of the same item there that the
    /// stored draft did not have) - how a reader takes over a line (B1);</item>
    /// <item>nothing else: no line added, none changed (item, unit, quantity, expiry, and the family's stock fields),
    /// none removed without being moved; the header ("Receive into") may keep it, never be set to it.</item>
    /// </list>
    /// <paramref name="stored"/> is read only for a restricted user (null for a new draft: every warehouse named must be
    /// theirs). For an unrestricted user: one primary-key seek.
    /// </summary>
    Task<string?> DraftRefusalAsync(int userId, WarehouseDraft requested, Func<Task<WarehouseDraft?>>? stored,
        CancellationToken cancellationToken = default);

    /// <summary>Per warehouse id that the user may not use, its sentence (the import's rows); empty for an unrestricted user.</summary>
    Task<IReadOnlyDictionary<int, string>> RefusalsByWarehouseAsync(int userId, IEnumerable<int> warehouseIds,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// (92) One line of a draft as the keep rule (A8) compares it: the warehouse its stock moves in (the header's when the
/// line names none), its item, and <paramref name="Key"/> - a value-equal tuple of the fields that say what moves (unit,
/// quantity, expiry and the family's own: the source line of a return, the order / invoice / container line of a goods
/// receipt). Prices and notes are not part of it: they move no stock, and the procedures re-price lines (price list,
/// average cost, the invoice line), so a line sent back unchanged would not compare equal on them.
/// </summary>
public sealed record WarehouseDraftLine(int? WarehouseId, int ItemId, object Key);

/// <summary>(92) A draft as the keep rule (A8) reads it: its header warehouse (null = none named) and its lines.</summary>
public sealed record WarehouseDraft(int? HeaderWarehouseId, IReadOnlyList<WarehouseDraftLine> Lines)
{
    /// <summary>Every warehouse the draft names: its lines' and its header's.</summary>
    public IEnumerable<int?> WarehouseIds => Lines.Select(line => line.WarehouseId).Append(HeaderWarehouseId);
}
