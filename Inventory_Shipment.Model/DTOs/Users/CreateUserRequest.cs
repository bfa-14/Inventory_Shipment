using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Users;

public sealed class CreateUserRequest
{
    [Required]
    [StringLength(50, MinimumLength = 3)]
    [RegularExpression("^[a-zA-Z0-9._-]+$", ErrorMessage = "Username may only contain letters, digits, '.', '_' and '-'.")]
    public string Username { get; init; } = string.Empty;

    [Required]
    [EmailAddress]
    [StringLength(256)]
    public string Email { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string FullName { get; init; } = string.Empty;

    [Required]
    [StringLength(128, MinimumLength = 8)]
    public string Password { get; init; } = string.Empty;

    /// <summary>Roles to assign to the new user. May be empty - the user then has no permissions.</summary>
    public int[] RoleIds { get; init; } = [];
}
