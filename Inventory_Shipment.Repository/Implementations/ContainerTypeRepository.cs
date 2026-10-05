using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ContainerTypeRepository : IContainerTypeRepository
{
    /// <summary>The columns the search procedure will sort by; anything else falls back to the code.</summary>
    private static readonly string[] SortColumns = ["TypeCode", "TypeName", "IsActive"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ContainerTypeRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The DTO plus the window count the procedure adds; serialized as the DTO, so the count stays out of the JSON.</summary>
    private sealed class SearchRow : ContainerTypeDto
    {
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<ContainerTypeDto> Items, int TotalCount)> SearchAsync(
        ContainerTypeQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.IsActive,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "TypeCode",
            SortDirection = string.Equals(query.SortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<SearchRow>(new CommandDefinition(
            "masterdata.usp_ContainerType_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows, rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    public async Task<ContainerTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ContainerTypeDto>(new CommandDefinition(
            "masterdata.usp_ContainerType_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<ContainerTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ContainerTypeLookupDto>(new CommandDefinition(
            "masterdata.usp_ContainerType_Lookup", new { ActiveOnly = activeOnly, IncludeId = includeId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<int> SaveAsync(
        SaveContainerTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@TypeCode", request.TypeCode, DbType.String, size: 10);
        parameters.Add("@TypeName", request.TypeName, DbType.String, size: 100);
        parameters.Add("@MaxWeightKg", request.MaxWeightKg, DbType.Decimal, precision: 18, scale: 3);
        parameters.Add("@MaxVolumeCbm", request.MaxVolumeCbm, DbType.Decimal, precision: 18, scale: 3);
        parameters.Add("@Description", request.Description, DbType.String, size: 500);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("masterdata.usp_ContainerType_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_ContainerType_SetActive",
            new { Id = id, IsActive = isActive, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_ContainerType_Delete", new { Id = id, UserId = userId }, cancellationToken);

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
