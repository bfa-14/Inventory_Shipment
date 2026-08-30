using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Security;

namespace Inventory_Shipment.Service.Interfaces;

public interface ITokenService
{
    /// <summary>
    /// Creates a signed JWT access token for the user, carrying one "role" claim per role name and
    /// one "permission" claim per permission code.
    /// </summary>
    (string Token, DateTime ExpiresAtUtc) CreateAccessToken(User user, UserAccess access);

    /// <summary>Creates a cryptographically random, URL-safe refresh token (raw value, sent to the client).</summary>
    string GenerateRefreshToken();

    /// <summary>SHA-256 hex digest of a refresh token - the only form that is stored.</summary>
    string HashToken(string token);
}
