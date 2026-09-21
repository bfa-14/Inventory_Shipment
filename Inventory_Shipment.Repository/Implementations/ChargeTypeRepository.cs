using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ChargeTypeRepository : IChargeTypeRepository
{
    /// <summary>The columns the search procedure will sort by; anything else falls back to the code.</summary>
    private static readonly string[] SortColumns = ["ChargeCode", "ChargeName", "AllocationMethod", "IsActive", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ChargeTypeRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The search row: the DTO's own columns plus the window count the procedure adds.</summary>
    private sealed class SearchRow
    {
        public int Id { get; init; }
        public string ChargeCode { get; init; } = string.Empty;
        public string ChargeName { get; init; } = string.Empty;
        public string AllocationMethod { get; init; } = string.Empty;
        public bool IncludeInLandedCost { get; init; }
        public bool IsRecoverableTax { get; init; }
        public string? Description { get; init; }
        public bool IsActive { get; init; }
        public int UsageCount { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public ChargeTypeDto ToDto() => new()
        {
            Id = Id,
            ChargeCode = ChargeCode,
            ChargeName = ChargeName,
            AllocationMethod = AllocationMethod,
            IncludeInLandedCost = IncludeInLandedCost,
            IsRecoverableTax = IsRecoverableTax,
            Description = Description,
            IsActive = IsActive,
            UsageCount = UsageCount,
            CreatedAtUtc = CreatedAtUtc,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<ChargeTypeDto> Items, int TotalCount)> SearchAsync(
        ChargeTypeQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            AllocationMethod = ChargeAllocationMethods.Normalize(query.AllocationMethod),
            query.IncludeInLandedCost,
            query.IsActive,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "ChargeCode",
            SortDirection = string.Equals(query.SortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<SearchRow>(new CommandDefinition(
            "purchase.usp_ChargeType_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var list = rows.AsList();
        var total = list.Count > 0 ? list[0].TotalCount : 0;
        return (list.Select(r => r.ToDto()).ToList(), total);
    }

    public async Task<IReadOnlyList<ChargeTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ChargeTypeLookupDto>(new CommandDefinition(
            "purchase.usp_ChargeType_Lookup", new { ActiveOnly = activeOnly, IncludeId = includeId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    /// <summary>
    /// One type by id. There is no _Get procedure — the search with the id's own code would be a
    /// guess — so the row is read here, with the same UsageCount the list shows, because the page
    /// decides whether Delete is offered from it.
    /// </summary>
    public async Task<ChargeTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT c.Id, c.ChargeCode, c.ChargeName, c.AllocationMethod, c.IncludeInLandedCost, c.IsRecoverableTax,
                   c.Description, c.IsActive,
                   UsageCount = (SELECT COUNT(*) FROM purchase.PurchaseCharges pc WHERE pc.ChargeTypeId = c.Id),
                   c.CreatedAtUtc, c.UpdatedAtUtc, c.RowVersion
            FROM purchase.ChargeTypes c
            WHERE c.Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ChargeTypeDto>(new CommandDefinition(
            sql, new { Id = id }, cancellationToken: cancellationToken));
    }

    public async Task<int> SaveAsync(
        SaveChargeTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@ChargeCode", request.ChargeCode, DbType.String, size: 10);
        parameters.Add("@ChargeName", request.ChargeName, DbType.String, size: 100);
        parameters.Add("@AllocationMethod", ChargeAllocationMethods.Normalize(request.AllocationMethod) ?? request.AllocationMethod, DbType.String, size: 10);
        parameters.Add("@IncludeInLandedCost", request.IncludeInLandedCost, DbType.Boolean);
        parameters.Add("@IsRecoverableTax", request.IsRecoverableTax, DbType.Boolean);
        parameters.Add("@Description", request.Description, DbType.String, size: 500);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "purchase.usp_ChargeType_Save", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_ChargeType_SetActive",
            new { Id = id, IsActive = isActive, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_ChargeType_Delete", new { Id = id, UserId = userId }, cancellationToken);

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
