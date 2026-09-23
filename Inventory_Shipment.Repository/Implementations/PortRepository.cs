using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PortRepository : IPortRepository
{
    /// <summary>The columns the search procedure will sort by; anything else falls back to the code.</summary>
    private static readonly string[] SortColumns = ["PortCode", "PortName", "CountryCode", "Kind", "IsActive"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public PortRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The DTO plus the window count the procedure adds; serialized as the DTO, so the count stays out of the JSON.</summary>
    private sealed class SearchRow : PortDto
    {
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<PortDto> Items, int TotalCount)> SearchAsync(
        PortQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            Kind = PortKinds.Normalize(query.Kind),
            query.IsActive,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "PortCode",
            SortDirection = string.Equals(query.SortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<SearchRow>(new CommandDefinition(
            "masterdata.usp_Port_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows, rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    public async Task<PortDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<PortDto>(new CommandDefinition(
            "masterdata.usp_Port_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<PortLookupDto>> LookupAsync(
        string? kind = null, bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<PortLookupDto>(new CommandDefinition(
            "masterdata.usp_Port_Lookup", new { Kind = PortKinds.Normalize(kind), ActiveOnly = activeOnly, IncludeId = includeId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<int> SaveAsync(SavePortRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@PortCode", request.PortCode, DbType.String, size: 10);
        parameters.Add("@PortName", request.PortName, DbType.String, size: 100);
        parameters.Add("@CountryCode", string.IsNullOrWhiteSpace(request.CountryCode) ? null : request.CountryCode.Trim(), DbType.StringFixedLength, size: 2);
        parameters.Add("@Kind", PortKinds.Normalize(request.Kind) ?? request.Kind, DbType.String, size: 10);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("masterdata.usp_Port_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_Port_SetActive",
            new { Id = id, IsActive = isActive, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_Port_Delete", new { Id = id, UserId = userId }, cancellationToken);

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
