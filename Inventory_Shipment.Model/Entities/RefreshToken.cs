namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// Refresh token (table security.RefreshTokens). Only the SHA-256 hash of the token is stored;
/// the raw token is returned to the client once and never persisted.
/// </summary>
public class RefreshToken
{
    public long Id { get; set; }
    public int UserId { get; set; }
    public string TokenHash { get; set; } = string.Empty;
    public DateTime ExpiresAtUtc { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public string? CreatedByIp { get; set; }
    public DateTime? RevokedAtUtc { get; set; }
    public string? RevokedByIp { get; set; }
    public string? ReplacedByTokenHash { get; set; }
    public string? RevokeReason { get; set; }

    public bool IsRevoked => RevokedAtUtc.HasValue;
    public bool IsExpired(DateTime utcNow) => utcNow >= ExpiresAtUtc;
    public bool IsActive(DateTime utcNow) => !IsRevoked && !IsExpired(utcNow);
}
