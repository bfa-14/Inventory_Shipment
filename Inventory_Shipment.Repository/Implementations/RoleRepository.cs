using System.Data;
using Dapper;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class RoleRepository : IRoleRepository
{
    private const string SelectWithCounts = """
        SELECT r.Id, r.Name, r.Description, r.IsSystem, r.IsActive, r.CreatedAtUtc, r.UpdatedAtUtc,
               (SELECT COUNT(*) FROM security.UserRoles ur WHERE ur.RoleId = r.Id)       AS UserCount,
               (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.RoleId = r.Id) AS PermissionCount
        FROM security.Roles r
        """;

    private readonly ISqlConnectionFactory _connectionFactory;

    public RoleRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape Dapper maps the projection above onto.</summary>
    private sealed class RoleRow
    {
        public int Id { get; init; }
        public string Name { get; init; } = string.Empty;
        public string? Description { get; init; }
        public bool IsSystem { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int UserCount { get; init; }
        public int PermissionCount { get; init; }

        public RoleWithCounts ToRoleWithCounts() => new(
            new Role
            {
                Id = Id,
                Name = Name,
                Description = Description,
                IsSystem = IsSystem,
                IsActive = IsActive,
                CreatedAtUtc = CreatedAtUtc,
                UpdatedAtUtc = UpdatedAtUtc
            },
            UserCount,
            PermissionCount);
    }

    public async Task<IReadOnlyList<RoleWithCounts>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<RoleRow>(new CommandDefinition(
            SelectWithCounts + " ORDER BY r.IsSystem DESC, r.Name", cancellationToken: cancellationToken));
        return rows.Select(r => r.ToRoleWithCounts()).ToList();
    }

    public async Task<RoleWithCounts?> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var row = await connection.QuerySingleOrDefaultAsync<RoleRow>(new CommandDefinition(
            SelectWithCounts + " WHERE r.Id = @Id", new { Id = id }, cancellationToken: cancellationToken));
        return row?.ToRoleWithCounts();
    }

    public async Task<Role?> GetByNameAsync(string name, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<Role>(new CommandDefinition("""
            SELECT Id, Name, Description, IsSystem, IsActive, CreatedAtUtc, UpdatedAtUtc
            FROM security.Roles WHERE Name = @Name
            """, new { Name = name }, cancellationToken: cancellationToken));
    }

    public async Task<bool> NameExistsAsync(string name, int? excludeRoleId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<bool>(new CommandDefinition("""
            SELECT CASE WHEN EXISTS
                   (SELECT 1 FROM security.Roles WHERE Name = @Name AND (@ExcludeId IS NULL OR Id <> @ExcludeId))
                   THEN 1 ELSE 0 END
            """, new { Name = name, ExcludeId = excludeRoleId }, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<int>> GetPermissionIdsAsync(int roleId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var ids = await connection.QueryAsync<int>(new CommandDefinition(
            "SELECT PermissionId FROM security.RolePermissions WHERE RoleId = @RoleId ORDER BY PermissionId",
            new { RoleId = roleId }, cancellationToken: cancellationToken));
        return ids.AsList();
    }

    public async Task<int> CreateAsync(Role role, CancellationToken cancellationToken = default)
    {
        const string sql = """
            INSERT INTO security.Roles (Name, Description, IsSystem, IsActive, CreatedAtUtc)
            OUTPUT INSERTED.Id
            VALUES (@Name, @Description, @IsSystem, @IsActive, SYSUTCDATETIME());
            """;

        await using var connection = _connectionFactory.Create();
        try
        {
            var id = await connection.ExecuteScalarAsync<int>(new CommandDefinition(sql, new
            {
                role.Name,
                role.Description,
                role.IsSystem,
                role.IsActive
            }, cancellationToken: cancellationToken));

            role.Id = id;
            return id;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            throw new DuplicateRecordException("A role with that name already exists.", ex);
        }
    }

    public async Task<bool> UpdateAsync(Role role, CancellationToken cancellationToken = default)
    {
        const string sql = """
            UPDATE security.Roles
            SET Name         = @Name,
                Description  = @Description,
                IsActive     = @IsActive,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.ExecuteAsync(new CommandDefinition(sql, new
            {
                role.Id,
                role.Name,
                role.Description,
                role.IsActive
            }, cancellationToken: cancellationToken));
            return rows > 0;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            throw new DuplicateRecordException("A role with that name already exists.", ex);
        }
    }

    public async Task DeleteAsync(int roleId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition("security.usp_Role_Delete",
                new { RoleId = roleId }, commandType: CommandType.StoredProcedure,
                cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.ToSecurityRuleException(ex);
        }
    }

    public async Task SetPermissionsAsync(int roleId, IEnumerable<int> permissionIds, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition("security.usp_Role_SetPermissions",
                new { RoleId = roleId, PermissionIds = string.Join(",", permissionIds) },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.ToSecurityRuleException(ex);
        }
    }
}
