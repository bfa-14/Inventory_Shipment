using System.Data;
using System.Text.Json;
using Dapper;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PermissionRepository : IPermissionRepository
{
    private static readonly JsonSerializerOptions CatalogJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly ISqlConnectionFactory _connectionFactory;

    public PermissionRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<Permission>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<Permission>(new CommandDefinition("""
            SELECT Id, Code, Name, Module, Description, SortOrder
            FROM security.Permissions
            ORDER BY Module, SortOrder, Code
            """, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<IReadOnlyList<(int PermissionId, string RoleName)>> GetRoleNamesByPermissionAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<(int PermissionId, string RoleName)>(new CommandDefinition("""
            SELECT rp.PermissionId, r.Name AS RoleName
            FROM security.RolePermissions rp
            INNER JOIN security.Roles r ON r.Id = rp.RoleId
            ORDER BY rp.PermissionId, r.Name
            """, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task SyncCatalogAsync(IEnumerable<PermissionDefinition> catalog, CancellationToken cancellationToken = default)
    {
        var json = JsonSerializer.Serialize(catalog, CatalogJsonOptions);

        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition("security.usp_Permission_SyncCatalog",
            new { CatalogJson = json }, commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken));
    }
}
