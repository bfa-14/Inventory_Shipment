using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Users;

public sealed class UpdateUserRequest
{
    [Required]
    [StringLength(100)]
    public string FullName { get; init; } = string.Empty;

    [Required]
    [EmailAddress]
    [StringLength(256)]
    public string Email { get; init; } = string.Empty;
}
