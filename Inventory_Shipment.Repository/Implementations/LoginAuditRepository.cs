using Dapper;
using Inventory_Shipment.Model.DTOs.Security;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class LoginAuditRepository : ILoginAuditRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public LoginAuditRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task AddAsync(LoginAudit entry, CancellationToken cancellationToken = default)
    {
        const string sql = """
            INSERT INTO security.LoginAudit (Username, UserId, Succeeded, FailureReason, IpAddress, UserAgent, AttemptedAtUtc)
            VALUES (@Username, @UserId, @Succeeded, @FailureReason, @IpAddress, @UserAgent, @AttemptedAtUtc);
            """;

        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition(sql, entry, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<LoginAudit>> QueryAsync(LoginAuditQuery query, CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT TOP (@Take) Id, Username, UserId, Succeeded, FailureReason, IpAddress, UserAgent, AttemptedAtUtc
            FROM security.LoginAudit
            WHERE (@Username IS NULL OR Username = @Username)
              AND (@OnlyFailed = 0 OR Succeeded = 0)
            ORDER BY AttemptedAtUtc DESC, Id DESC;
            """;

        var username = string.IsNullOrWhiteSpace(query.Username) ? null : query.Username.Trim();

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<LoginAudit>(new CommandDefinition(sql, new
        {
            query.Take,
            Username = username,
            OnlyFailed = query.OnlyFailed
        }, cancellationToken: cancellationToken));

        return rows.AsList();
    }
}
