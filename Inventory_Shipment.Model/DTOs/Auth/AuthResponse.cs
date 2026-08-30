using Inventory_Shipment.Model.DTOs.Users;

namespace Inventory_Shipment.Model.DTOs.Auth;

public sealed class AuthResponse
{
    public string TokenType { get; init; } = "Bearer";
    public string AccessToken { get; init; } = string.Empty;
    public DateTime AccessTokenExpiresAtUtc { get; init; }
    public string RefreshToken { get; init; } = string.Empty;
    public DateTime RefreshTokenExpiresAtUtc { get; init; }
    public UserDto User { get; init; } = new();
}
