using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Security;

/// <summary>
/// (92) <see cref="IWarehouseAccessService"/> over security.usp_User_WarehouseRefusal. It decides nothing itself: it hands
/// the procedure the ids and returns its sentence, so a disabled button, an early refusal and the ledger trigger's
/// refusal say the same words.
/// </summary>
public sealed class WarehouseAccessService : IWarehouseAccessService
{
    private readonly IUserWarehouseRepository _access;

    public WarehouseAccessService(IUserWarehouseRepository access)
    {
        _access = access;
    }

    public async Task<string?> RefusalAsync(
        int userId, IEnumerable<int?> warehouseIds, CancellationToken cancellationToken = default)
    {
        var ids = Ids(warehouseIds);
        if (ids.Count == 0)
        {
            return null;
        }

        var answer = await _access.RefusalAsync(userId, ids, cancellationToken);
        return answer.IsUnrestricted ? null : answer.Message;
    }

    public async Task<string?> DraftRefusalAsync(int userId, WarehouseDraft requested, Func<Task<WarehouseDraft?>>? stored,
        CancellationToken cancellationToken = default)
    {
        // One call answers both "unrestricted?" (one primary-key seek, then nothing more) and the request's own sentence.
        var first = await _access.RefusalAsync(userId, Ids(requested.WarehouseIds), cancellationToken);
        if (first.IsUnrestricted)
        {
            return null;
        }

        var before = stored is null ? null : await stored();
        if (before is null)
        {
            return first.Message;   // a new draft: every warehouse it names must be the user's
        }

        // Which of the warehouses of the request and of the stored draft the user may not use: those are compared.
        var all = Ids(requested.WarehouseIds.Concat(before.WarehouseIds));
        var answer = await _access.RefusalAsync(userId, all, cancellationToken);
        var refused = answer.PerWarehouse.Select(p => p.WarehouseId).ToHashSet();
        if (refused.Count == 0)
        {
            return null;
        }

        var atFault = WarehousesAtFault(requested, before, refused);
        if (atFault.Count == 0)
        {
            return null;
        }

        var again = await _access.RefusalAsync(userId, atFault, cancellationToken);
        return again.IsUnrestricted ? null : again.Message;
    }

    /// <summary>
    /// (92) A8 LINE BY LINE: the warehouses the user may not use (<paramref name="refused"/>) in which the request does
    /// something other than keep the stored lines or move them out to one of the user's warehouses. Lines have no stable
    /// identity (a save replaces them all), so they are compared as multisets:
    /// 1. each request line in a refused warehouse must be a stored line of that warehouse with the same item and key -
    ///    otherwise it was added or changed there, and that warehouse is at fault;
    /// 2. each stored line of a refused warehouse that is left over must have moved: a request line of the same item
    ///    elsewhere, beyond the lines of that item the stored draft already had in the user's warehouses - otherwise it
    ///    was dropped, and its warehouse is at fault. A line moved to another refused warehouse counts as moved (that one
    ///    is at fault already, by 1), so the sentence names the warehouse the user chose, not the one the line left;
    /// 3. the header may keep a refused warehouse, never be set to one.
    /// </summary>
    internal static IReadOnlyCollection<int> WarehousesAtFault(WarehouseDraft requested, WarehouseDraft stored, ISet<int> refused)
    {
        var atFault = new HashSet<int>();
        bool IsRefused(int? id) => id is { } w && refused.Contains(w);

        if (requested.HeaderWarehouseId is { } header && refused.Contains(header) && header != stored.HeaderWarehouseId)
        {
            atFault.Add(header);
        }

        // 1. kept as stored, one for one
        var leftOver = stored.Lines.Where(line => IsRefused(line.WarehouseId)).ToList();
        var elsewhere = requested.Lines.Where(line => !IsRefused(line.WarehouseId)).ToList();
        foreach (var line in requested.Lines.Where(line => IsRefused(line.WarehouseId)))
        {
            var match = leftOver.FindIndex(s =>
                s.WarehouseId == line.WarehouseId && s.ItemId == line.ItemId && Equals(s.Key, line.Key));
            if (match < 0)
            {
                atFault.Add(line.WarehouseId!.Value);   // added, or changed
                elsewhere.Add(line);                    // ... and where a line that left may have gone (2)
            }
            else
            {
                leftOver.RemoveAt(match);
            }
        }

        // 2. the rest moved: per item, the request's other lines beyond those the stored draft had in the user's warehouses
        var moved = elsewhere.GroupBy(line => line.ItemId).ToDictionary(g => g.Key, g => g.Count());
        foreach (var line in stored.Lines.Where(line => !IsRefused(line.WarehouseId)))
        {
            if (moved.TryGetValue(line.ItemId, out var count))
            {
                moved[line.ItemId] = count - 1;
            }
        }

        foreach (var line in leftOver)
        {
            if (moved.TryGetValue(line.ItemId, out var count) && count > 0)
            {
                moved[line.ItemId] = count - 1;
            }
            else
            {
                atFault.Add(line.WarehouseId!.Value);   // dropped without being moved
            }
        }

        return atFault;
    }

    public async Task<string?> RefusalAsync(
        int userId, Func<Task<IEnumerable<int?>>> warehouseIds, CancellationToken cancellationToken = default)
    {
        var probe = await _access.RefusalAsync(userId, [], cancellationToken);
        return probe.IsUnrestricted
            ? null
            : await RefusalAsync(userId, await warehouseIds(), cancellationToken);
    }

    public async Task<IReadOnlyDictionary<int, string>> RefusalsByWarehouseAsync(
        int userId, IEnumerable<int> warehouseIds, CancellationToken cancellationToken = default)
    {
        var ids = warehouseIds.Where(id => id > 0).Distinct().ToList();
        if (ids.Count == 0)
        {
            return new Dictionary<int, string>();
        }

        var answer = await _access.RefusalAsync(userId, ids, cancellationToken);
        if (answer.IsUnrestricted)
        {
            return new Dictionary<int, string>();
        }

        var refusals = new Dictionary<int, string>();
        foreach (var (warehouseId, message) in answer.PerWarehouse)
        {
            refusals.TryAdd(warehouseId, message);
        }

        return refusals;
    }

    private static List<int> Ids(IEnumerable<int?>? ids)
        => (ids ?? []).Where(id => id is > 0).Select(id => id!.Value).Distinct().ToList();
}

/// <summary>(92) How every family answers a refusal: 403 with the database's sentence and the code the pages read.</summary>
public static class WarehouseAccess
{
    /// <summary>The ProblemDetails code of a warehouse refusal (error 50010).</summary>
    public const string Code = "WAREHOUSE_ACCESS";

    public static Result<T> Failure<T>(string refusal) => Result<T>.Failure(ErrorType.Forbidden, refusal, Code);

    public static Result Failure(string refusal) => Result.Failure(ErrorType.Forbidden, refusal, Code);
}
