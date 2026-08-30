using System.Data;
using Dapper;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class UserRepository : IUserRepository
{
    // Roles are not columns here: a user holds zero or more roles through security.UserRoles
    // (the legacy single-role column was dropped by 04_Security_DropLegacyRoleColumn.sql).
    private const string SelectColumns = """
        SELECT Id, Username, Email, FullName, PasswordHash, IsActive,
               FailedLoginAttempts, LockoutEndUtc, LastLoginAtUtc, CreatedAtUtc, UpdatedAtUtc
        FROM security.Users
        """;

    private readonly ISqlConnectionFactory _connectionFactory;

    public UserRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<User?> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<User>(new CommandDefinition(
            SelectColumns + " WHERE Id = @Id", new { Id = id }, cancellationToken: cancellationToken));
    }

    public async Task<User?> GetByUsernameOrEmailAsync(string usernameOrEmail, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QueryFirstOrDefaultAsync<User>(new CommandDefinition(
            SelectColumns + " WHERE Username = @Value OR Email = @Value",
            new { Value = usernameOrEmail }, cancellationToken: cancellationToken));
    }

    public async Task<bool> UsernameExistsAsync(string username, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM security.Users WHERE Username = @Username) THEN 1 ELSE 0 END",
            new { Username = username }, cancellationToken: cancellationToken));
    }

    public async Task<bool> EmailExistsAsync(string email, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM security.Users WHERE Email = @Email) THEN 1 ELSE 0 END",
            new { Email = email }, cancellationToken: cancellationToken));
    }

    public async Task<bool> EmailExistsForOtherUserAsync(string email, int excludeUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<bool>(new CommandDefinition("""
            SELECT CASE WHEN EXISTS (SELECT 1 FROM security.Users WHERE Email = @Email AND Id <> @ExcludeId)
                   THEN 1 ELSE 0 END
            """, new { Email = email, ExcludeId = excludeUserId }, cancellationToken: cancellationToken));
    }

    public async Task<int> CountAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM security.Users", cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<User>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var users = await connection.QueryAsync<User>(new CommandDefinition(
            SelectColumns + " ORDER BY Username", cancellationToken: cancellationToken));
        return users.AsList();
    }

    public async Task<int> CreateAsync(User user, CancellationToken cancellationToken = default)
    {
        const string sql = """
            INSERT INTO security.Users (Username, Email, FullName, PasswordHash, IsActive, CreatedAtUtc)
            OUTPUT INSERTED.Id
            VALUES (@Username, @Email, @FullName, @PasswordHash, @IsActive, SYSUTCDATETIME());
            """;

        await using var connection = _connectionFactory.Create();
        try
        {
            var id = await connection.ExecuteScalarAsync<int>(new CommandDefinition(sql, new
            {
                user.Username,
                user.Email,
                user.FullName,
                user.PasswordHash,
                user.IsActive
            }, cancellationToken: cancellationToken));

            user.Id = id;
            return id;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            throw new DuplicateRecordException("A user with the same username or e-mail already exists.", ex);
        }
    }

    public async Task<UserAccess> GetAccessAsync(int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "security.usp_User_GetAccess", new { UserId = userId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var roles = (await grid.ReadAsync<RoleRef>()).AsList();
        var permissions = (await grid.ReadAsync<string>()).AsList();

        return new UserAccess(roles, permissions);
    }

    public async Task SetRolesAsync(int userId, IEnumerable<int> roleIds, int? assignedBy, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition("security.usp_User_SetRoles", new
            {
                UserId = userId,
                RoleIds = string.Join(",", roleIds),
                AssignedBy = assignedBy
            }, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.ToSecurityRuleException(ex);
        }
    }

    public async Task<IReadOnlyList<(int UserId, int RoleId, string RoleName)>> GetRolesForUsersAsync(
        IEnumerable<int> userIds, CancellationToken cancellationToken = default)
    {
        var ids = userIds as IReadOnlyCollection<int> ?? userIds.ToList();
        if (ids.Count == 0)
        {
            return [];
        }

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<(int UserId, int RoleId, string RoleName)>(new CommandDefinition("""
            SELECT ur.UserId, ur.RoleId, r.Name AS RoleName
            FROM security.UserRoles ur
            INNER JOIN security.Roles r ON r.Id = ur.RoleId
            WHERE ur.UserId IN @UserIds
            ORDER BY ur.UserId, r.Name
            """, new { UserIds = ids }, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<int> CountActiveSystemAdminsAsync(int? excludeUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<int>(new CommandDefinition("""
            SELECT COUNT(DISTINCT u.Id)
            FROM security.Users u
            INNER JOIN security.UserRoles ur ON ur.UserId = u.Id
            INNER JOIN security.Roles r ON r.Id = ur.RoleId
            WHERE r.IsSystem = 1 AND u.IsActive = 1
              AND (@ExcludeId IS NULL OR u.Id <> @ExcludeId)
            """, new { ExcludeId = excludeUserId }, cancellationToken: cancellationToken));
    }

    public async Task<bool> UpdateProfileAsync(int userId, string fullName, string email, CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.Users
            SET FullName     = @FullName,
                Email        = @Email,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.ExecuteAsync(new CommandDefinition(sql,
                new { Id = userId, FullName = fullName, Email = email }, cancellationToken: cancellationToken));
            return rows > 0;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            throw new DuplicateRecordException("That e-mail address is already registered.", ex);
        }
    }

    public async Task<(int FailedLoginAttempts, DateTime? LockoutEndUtc)> RegisterFailedLoginAsync(
        int userId, int maxAttempts, int lockoutMinutes, CancellationToken cancellationToken = default)
    {
        // Both CASE expressions read the pre-update value of FailedLoginAttempts (standard UPDATE semantics).
        const string sql = """
            UPDATE security.Users
            SET FailedLoginAttempts = CASE WHEN FailedLoginAttempts + 1 >= @MaxAttempts THEN 0 ELSE FailedLoginAttempts + 1 END,
                LockoutEndUtc       = CASE WHEN FailedLoginAttempts + 1 >= @MaxAttempts
                                           THEN DATEADD(MINUTE, @LockoutMinutes, SYSUTCDATETIME())
                                           ELSE LockoutEndUtc END,
                UpdatedAtUtc        = SYSUTCDATETIME()
            OUTPUT INSERTED.FailedLoginAttempts, INSERTED.LockoutEndUtc
            WHERE Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleAsync<(int, DateTime?)>(new CommandDefinition(sql,
            new { Id = userId, MaxAttempts = maxAttempts, LockoutMinutes = lockoutMinutes },
            cancellationToken: cancellationToken));
    }

    public async Task RegisterSuccessfulLoginAsync(int userId, CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.Users
            SET FailedLoginAttempts = 0,
                LockoutEndUtc       = NULL,
                LastLoginAtUtc      = SYSUTCDATETIME()
            WHERE Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition(sql, new { Id = userId }, cancellationToken: cancellationToken));
    }

    public async Task UpdatePasswordHashAsync(int userId, string passwordHash, CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.Users
            SET PasswordHash = @PasswordHash,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition(sql, new { Id = userId, PasswordHash = passwordHash },
            cancellationToken: cancellationToken));
    }

    public async Task<bool> SetActiveAsync(int userId, bool isActive, CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.Users
            SET IsActive     = @IsActive,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        var rows = await connection.ExecuteAsync(new CommandDefinition(sql, new { Id = userId, IsActive = isActive },
            cancellationToken: cancellationToken));
        return rows > 0;
    }
}
