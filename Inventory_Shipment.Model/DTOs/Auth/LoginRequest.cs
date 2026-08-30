using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Auth;

public sealed class LoginRequest
{
    /// <summary>Username or e-mail address.</summary>
    [Required]
    [StringLength(256, MinimumLength = 1)]
    public string Username { get; init; } = string.Empty;

    [Required]
    [StringLength(128, MinimumLength = 1)]
    public string Password { get; init; } = string.Empty;
}
