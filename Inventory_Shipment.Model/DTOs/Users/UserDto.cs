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
}
