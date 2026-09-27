using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class MovementTypeRepository : IMovementTypeRepository
{
    /// <summary>The columns the search procedure will sort by; anything else falls back to the sort order.</summary>
    private static readonly string[] SortColumns = ["SortOrder", "TypeCode", "TypeName", "Stage", "IsActive"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public MovementTypeRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The DTO plus the window count the procedure adds; serialized as the DTO, so the count stays out of the JSON.</summary>
    private sealed class SearchRow : MovementTypeDto
    {
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<MovementTypeDto> Items, int TotalCount)> SearchAsync(
        MovementTypeQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            Stage = MovementStages.Normalize(query.Stage),
            query.IsActive,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "SortOrder",
            SortDirection = string.Equals(query.SortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<SearchRow>(new CommandDefinition(
            "masterdata.usp_MovementType_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows, rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    public async Task<MovementTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<MovementTypeDto>(new CommandDefinition(
            "masterdata.usp_MovementType_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<MovementTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<MovementTypeLookupDto>(new CommandDefinition(
            "masterdata.usp_MovementType_Lookup", new { ActiveOnly = activeOnly, IncludeId = includeId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<int> SaveAsync(SaveMovementTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@TypeCode", request.TypeCode, DbType.String, size: 10);
        parameters.Add("@TypeName", request.TypeName, DbType.String, size: 100);
        parameters.Add("@Stage", MovementStages.Normalize(request.Stage) ?? request.Stage, DbType.String, size: 10);
        parameters.Add("@SortOrder", request.SortOrder, DbType.Int32);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("masterdata.usp_MovementType_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_MovementType_SetActive",
            new { Id = id, IsActive = isActive, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_MovementType_Delete", new { Id = id, UserId = userId }, cancellationToken);

    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }
}
