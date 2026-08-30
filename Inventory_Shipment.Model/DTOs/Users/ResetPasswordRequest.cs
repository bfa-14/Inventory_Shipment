using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Users;

/// <summary>Administrator sets a new password for a user (all of that user's sessions are revoked).</summary>
public sealed class ResetPasswordRequest
{
    [Required]
    [StringLength(128, MinimumLength = 8)]
    public string NewPassword { get; init; } = string.Empty;
}
