using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Auth;
using Inventory_Shipment.Model.DTOs.Users;

namespace Inventory_Shipment.Service.Interfaces;

public interface IAuthService
{
    Task<Result<AuthResponse>> LoginAsync(LoginRequest request, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken = default);

    Task<Result<AuthResponse>> RefreshAsync(string refreshToken, string? ipAddress,
        CancellationToken cancellationToken = default);

    /// <summary>Revokes one refresh token. Idempotent - succeeds even if the token is unknown.</summary>
    Task<Result> LogoutAsync(string refreshToken, string? ipAddress, CancellationToken cancellationToken = default);

    /// <summary>Revokes every refresh token of the user ("sign out everywhere").</summary>
    Task<Result> LogoutAllAsync(int userId, string? ipAddress, CancellationToken cancellationToken = default);

    Task<Result<UserDto>> GetCurrentUserAsync(int userId, CancellationToken cancellationToken = default);

    Task<Result> ChangePasswordAsync(int userId, ChangePasswordRequest request, string? ipAddress,
        CancellationToken cancellationToken = default);
}
