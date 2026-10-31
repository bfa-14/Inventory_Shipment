using Inventory_Shipment.Model.DTOs.Users;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// (92) Warehouse access per user: who may move stock in which warehouse (security.Users.AllWarehouses and
/// security.UserWarehouses). THE RULE AND ITS SENTENCE ARE THE DATABASE'S (security.fn_User_CanUseWarehouse,
/// fn_User_WarehouseRefusal): this asks, it never decides. Nothing is cached (M8): each call reads the database, one
/// primary-key seek for a user with All warehouses.
/// </summary>
public interface IUserWarehouseRepository
{
    /// <summary>
    /// security.usp_User_WarehouseRefusal: whether the user is unrestricted (All warehouses, or a system administrator),
    /// the one sentence for every id the user may not use (null when none), and each such id with its own one-warehouse
    /// sentence. Ids that are not warehouses are ignored. No ids: only the first answer.
    /// </summary>
    Task<(bool IsUnrestricted, string? Message, IReadOnlyList<(int WarehouseId, string Message)> PerWarehouse)> RefusalAsync(
        int userId, IEnumerable<int> warehouseIds, CancellationToken cancellationToken = default);

    /// <summary>security.usp_User_Warehouses_Get: the dialog. Throws <c>SecurityRuleException</c> 50003 for an unknown user.</summary>
    Task<UserWarehousesDto> GetAsync(int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// security.usp_User_SetWarehouses: All warehouses, or only these (a ticked parent covers its tree; one audit row per
    /// real change). Throws <c>SecurityRuleException</c> 50003 (user not found) or 50011 (the dialog's own refusals).
    /// </summary>
    Task SetAsync(int userId, bool allWarehouses, IReadOnlyCollection<int> warehouseIds, int? changedBy,
        CancellationToken cancellationToken = default);

    /// <summary>security.usp_User_WarehouseSummaries: the Users list's column - every tick, and each user's flags.</summary>
    Task<UserWarehouseSummaries> SummariesAsync(CancellationToken cancellationToken = default);
}

/// <summary>(92) The two result sets of security.usp_User_WarehouseSummaries.</summary>
public sealed class UserWarehouseSummaries
{
    /// <summary>One row per tick, by user then code (users with All warehouses have none).</summary>
    public IReadOnlyList<UserWarehouseTick> Ticks { get; init; } = [];

    /// <summary>One row per user.</summary>
    public IReadOnlyList<UserWarehouseFlags> Users { get; init; } = [];
}

public sealed class UserWarehouseTick
{
    public int UserId { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public string BranchCode { get; init; } = string.Empty;
    public bool IsActive { get; init; }
    public int ChildCount { get; init; }
}

public sealed class UserWarehouseFlags
{
    public int UserId { get; init; }
    public bool AllWarehouses { get; init; }
    public bool IsSystemAdministrator { get; init; }
}
