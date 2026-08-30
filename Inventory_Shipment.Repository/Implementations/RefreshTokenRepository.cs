using Dapper;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class RefreshTokenRepository : IRefreshTokenRepository
{
    private const string SelectColumns = """
        SELECT Id, UserId, TokenHash, ExpiresAtUtc, CreatedAtUtc, CreatedByIp,
               RevokedAtUtc, RevokedByIp, ReplacedByTokenHash, RevokeReason
        FROM security.RefreshTokens
        """;

    private const string InsertSql = """
        INSERT INTO security.RefreshTokens (UserId, TokenHash, ExpiresAtUtc, CreatedAtUtc, CreatedByIp)
        VALUES (@UserId, @TokenHash, @ExpiresAtUtc, @CreatedAtUtc, @CreatedByIp);
        """;

    private readonly ISqlConnectionFactory _connectionFactory;

    public RefreshTokenRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task CreateAsync(RefreshToken token, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition(InsertSql, token, cancellationToken: cancellationToken));
    }

    public async Task<RefreshToken?> GetByTokenHashAsync(string tokenHash, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<RefreshToken>(new CommandDefinition(
            SelectColumns + " WHERE TokenHash = @TokenHash", new { TokenHash = tokenHash },
            cancellationToken: cancellationToken));
    }

    public async Task<bool> RotateAsync(string oldTokenHash, RefreshToken newToken, string? ipAddress,
        CancellationToken cancellationToken = default)
    {
        const string revokeSql = """
            UPDATE security.RefreshTokens
            SET RevokedAtUtc        = SYSUTCDATETIME(),
                RevokedByIp         = @IpAddress,
                ReplacedByTokenHash = @NewTokenHash,
                RevokeReason        = N'Rotated'
            WHERE TokenHash = @OldTokenHash
              AND RevokedAtUtc IS NULL;
            """;

        await using var connection = _connectionFactory.Create();
        await connection.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        var revoked = await connection.ExecuteAsync(new CommandDefinition(revokeSql,
            new { IpAddress = ipAddress, NewTokenHash = newToken.TokenHash, OldTokenHash = oldTokenHash },
            transaction, cancellationToken: cancellationToken));

        if (revoked == 0)
        {
            await transaction.RollbackAsync(cancellationToken);
            return false;
        }

        await connection.ExecuteAsync(new CommandDefinition(InsertSql, newToken, transaction,
            cancellationToken: cancellationToken));
        await transaction.CommitAsync(cancellationToken);
        return true;
    }

    public async Task<int> RevokeAsync(string tokenHash, string? ipAddress, string reason,
        CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.RefreshTokens
            SET RevokedAtUtc = SYSUTCDATETIME(),
                RevokedByIp  = @IpAddress,
                RevokeReason = @Reason
            WHERE TokenHash = @TokenHash
              AND RevokedAtUtc IS NULL;
            """;

        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteAsync(new CommandDefinition(sql,
            new { TokenHash = tokenHash, IpAddress = ipAddress, Reason = reason }, cancellationToken: cancellationToken));
    }

    public async Task<int> RevokeAllForUserAsync(int userId, string? ipAddress, string reason,
        CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.RefreshTokens
            SET RevokedAtUtc = SYSUTCDATETIME(),
                RevokedByIp  = @IpAddress,
                RevokeReason = @Reason
            WHERE UserId = @UserId
              AND RevokedAtUtc IS NULL
              AND ExpiresAtUtc > SYSUTCDATETIME();
            """;

        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteAsync(new CommandDefinition(sql,
            new { UserId = userId, IpAddress = ipAddress, Reason = reason }, cancellationToken: cancellationToken));
    }

    public async Task<int> DeleteExpiredAsync(DateTime expiredBeforeUtc, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM security.RefreshTokens WHERE ExpiresAtUtc < @ExpiredBeforeUtc",
            new { ExpiredBeforeUtc = expiredBeforeUtc }, cancellationToken: cancellationToken));
    }
}
