using System.Text.Json.Serialization;

namespace Inventory_Shipment.Model.DTOs.Users;

/// <summary>Public view of a user - never includes the password hash.</summary>
public sealed class UserDto
{
    public int Id { get; init; }
    public string Username { get; init; } = string.Empty;
    public string Email { get; init; } = string.Empty;
    public string FullName { get; init; } = string.Empty;

    /// <summary>Names of the roles the user holds.</summary>
    public string[] Roles { get; init; } = [];

    /// <summary>Ids of the roles the user holds (what the role editor posts back).</summary>
    public int[] RoleIds { get; init; } = [];

    /// <summary>Flattened permission codes granted by those roles.</summary>
    public string[] Permissions { get; init; } = [];

    public bool IsActive { get; init; }
    public DateTime? LastLoginAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }

    /*
     * (92) WAREHOUSE ACCESS, ON THE USERS LIST ONLY (GET api/users, security.usp_User_WarehouseSummaries). Sign-in,
     * refresh and "me" answer this same class and must keep their shape (access is looked up per request, never carried
     * in the session, M8): there these stay null and are left out of the JSON. Absent means All warehouses.
     */

    /// <summary>(92) True = every warehouse (the default of every user); false = only <see cref="Warehouses"/>.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? AllWarehouses { get; init; }

    /// <summary>(92) Holds an active system role: uses every warehouse whatever is set ("All (administrator)").</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? IsSystemAdministrator { get; init; }

    /// <summary>(92) The ticked warehouses, by code; empty with All warehouses.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public UserWarehouseRefDto[]? Warehouses { get; init; }
}

/// <summary>(92) A ticked warehouse as the Users list shows it (a badge of its code).</summary>
public sealed class UserWarehouseRefDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string BranchCode { get; init; } = string.Empty;
    public bool IsActive { get; init; }

    /// <summary>A parent: the tick gives every warehouse under it, also those added later.</summary>
    public bool HasChildren { get; init; }
}
