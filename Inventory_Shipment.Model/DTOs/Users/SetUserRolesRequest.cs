using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Users;

public sealed class SetUserRolesRequest
{
    /// <summary>The complete set of roles the user should hold. An empty array removes every role.</summary>
    [Required]
    public int[] RoleIds { get; init; } = [];
}
