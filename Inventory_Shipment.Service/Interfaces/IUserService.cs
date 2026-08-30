using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Users;

namespace Inventory_Shipment.Service.Interfaces;

public interface IUserService
{
    Task<Result<IReadOnlyList<UserDto>>> GetAllAsync(CancellationToken cancellationToken = default);

    Task<Result<UserDto>> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<UserDto>> CreateAsync(CreateUserRequest request, int actingUserId, CancellationToken cancellationToken = default);

    /// <summary>Updates the user's profile (full name and e-mail).</summary>
    Task<Result> UpdateAsync(int id, UpdateUserRequest request, CancellationToken cancellationToken = default);

    /// <summary>Replaces the user's roles.</summary>
    Task<Result> SetRolesAsync(int id, IEnumerable<int> roleIds, int actingUserId, CancellationToken cancellationToken = default);

    /// <summary>Activates or deactivates a user. Deactivation also revokes the user's refresh tokens.</summary>
    Task<Result> SetActiveAsync(int id, bool isActive, int actingUserId, CancellationToken cancellationToken = default);

    /// <summary>Administrative password reset; revokes the user's refresh tokens.</summary>
    Task<Result> ResetPasswordAsync(int id, string newPassword, CancellationToken cancellationToken = default);
}
