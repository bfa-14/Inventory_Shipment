using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IRefreshTokenRepository
{
    Task CreateAsync(RefreshToken token, CancellationToken cancellationToken = default);

    Task<RefreshToken?> GetByTokenHashAsync(string tokenHash, CancellationToken cancellationToken = default);

    /// <summary>
    /// Atomically revokes the token identified by <paramref name="oldTokenHash"/> and inserts
    /// <paramref name="newToken"/>. Returns false if the old token was already revoked or does not exist
    /// (which the service treats as token reuse).
    /// </summary>
    Task<bool> RotateAsync(string oldTokenHash, RefreshToken newToken, string? ipAddress,
        CancellationToken cancellationToken = default);

    /// <summary>Revokes a single active token. Returns the number of rows affected (0 or 1).</summary>
    Task<int> RevokeAsync(string tokenHash, string? ipAddress, string reason, CancellationToken cancellationToken = default);

    /// <summary>Revokes every active token of a user (logout everywhere / password change / reuse detected).</summary>
    Task<int> RevokeAllForUserAsync(int userId, string? ipAddress, string reason, CancellationToken cancellationToken = default);

    /// <summary>Housekeeping: deletes tokens that expired before <paramref name="expiredBeforeUtc"/>.</summary>
    Task<int> DeleteExpiredAsync(DateTime expiredBeforeUtc, CancellationToken cancellationToken = default);
}
