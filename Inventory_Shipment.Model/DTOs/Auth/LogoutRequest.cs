using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Auth;

public sealed class LogoutRequest
{
    [Required]
    [StringLength(512, MinimumLength = 16)]
    public string RefreshToken { get; init; } = string.Empty;
}
