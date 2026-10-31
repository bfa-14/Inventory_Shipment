namespace Inventory_Shipment.Model.DTOs.Users;

/// <summary>
/// (92) "Warehouses of {user}": where a user may move stock - post, cancel and delete documents, receive goods, dispatch
/// and receive transfers, set stock levels (security.usp_User_Warehouses_Get). Viewing is never limited.
/// </summary>
public sealed class UserWarehousesDto
{
    public int UserId { get; init; }
    public string Username { get; init; } = string.Empty;
    public string FullName { get; init; } = string.Empty;

    /// <summary>True = every warehouse, including those added later; false = only <see cref="Warehouses"/>.</summary>
    public bool AllWarehouses { get; init; }

    /// <summary>System administrators use every warehouse whatever is set; the setting applies if the Admin role is taken away.</summary>
    public bool IsSystemAdministrator { get; init; }

    /// <summary>The warehouses at the bottom of the tree (not On the way) that the ticks give: what the user may really use.</summary>
    public int UsableCount { get; init; }

    /// <summary>The ticked warehouses, by code. Meaningful only while <see cref="AllWarehouses"/> is false.</summary>
    public IReadOnlyList<UserWarehouseDto> Warehouses { get; init; } = [];

    /// <summary>Every change, newest first (the last 100), a deleted ticked warehouse included.</summary>
    public IReadOnlyList<UserWarehouseChangeDto> History { get; init; } = [];
}

/// <summary>(92) One ticked warehouse of the dialog.</summary>
public sealed class UserWarehouseDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;

    /// <summary>An inactive warehouse stays ticked (it may be reactivated): the dialog shows "(inactive)".</summary>
    public bool IsActive { get; init; }

    /// <summary>A parent: the tick gives every warehouse under it, also those added later.</summary>
    public bool HasChildren { get; init; }

    public DateTime GrantedAtUtc { get; init; }

    /// <summary>Who ticked it ("-" when unknown).</summary>
    public string GrantedByName { get; init; } = string.Empty;
}

/// <summary>(92) One change of a user's warehouses: "All warehouses" → "Only: LKS-01", who and when.</summary>
public sealed class UserWarehouseChangeDto
{
    public long Id { get; init; }
    public string Before { get; init; } = string.Empty;
    public string After { get; init; } = string.Empty;
    public DateTime ChangedAtUtc { get; init; }
    public string? ChangedByName { get; init; }
}

/// <summary>
/// (92) PUT api/users/{id}/warehouses. <see cref="AllWarehouses"/> is required (null is refused with "Choose All
/// warehouses, or tick the warehouses this user may use."); the ids count only when it is false. None ticked is allowed:
/// the user then moves stock nowhere.
/// </summary>
public sealed class SetUserWarehousesRequest
{
    public bool? AllWarehouses { get; init; }

    /// <summary>The ticks (null or missing = none): with All warehouses they are cleared whatever is sent.</summary>
    public int[]? WarehouseIds { get; init; } = [];
}
