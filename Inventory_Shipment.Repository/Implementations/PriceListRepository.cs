using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PriceListRepository : IPriceListRepository
{
    /// <summary>Columns the search procedure accepts; anything else falls back to PriceListCode.</summary>
    private static readonly string[] SortColumns =
        ["PriceListCode", "PriceListName", "CurrencyCode", "IsActive", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public PriceListRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape the search procedure returns: every column plus the windowed total.</summary>
    private sealed class PriceListRow
    {
        public int Id { get; init; }
        public string PriceListCode { get; init; } = string.Empty;
        public string PriceListName { get; init; } = string.Empty;
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public string CurrencyName { get; init; } = string.Empty;
        public byte DecimalPlaces { get; init; }
        public string? Description { get; init; }
        public bool IsActive { get; init; }
        public int PriceCount { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public PriceList ToPriceList() => new()
        {
            Id = Id,
            PriceListCode = PriceListCode,
            PriceListName = PriceListName,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            CurrencyName = CurrencyName,
            DecimalPlaces = DecimalPlaces,
            Description = Description,
            IsActive = IsActive,
            PriceCount = PriceCount,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            UpdatedAtUtc = UpdatedAtUtc,
            UpdatedBy = UpdatedBy,
            RowVersion = RowVersion
        };
    }

    public async Task<(IReadOnlyList<PriceList> Items, int TotalCount)> SearchAsync(
        PriceListQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.CurrencyId,
            query.IsActive,
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = ResolveSortDirection(query.SortDir),
            PageNumber = query.Page,
            query.PageSize
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<PriceListRow>(new CommandDefinition(
                "masterdata.usp_PriceList_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats the same COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToPriceList()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<PriceList?> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<PriceList>(new CommandDefinition(
                "masterdata.usp_PriceList_Get", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> CreateAsync(
        PriceList priceList, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PriceListCode", priceList.PriceListCode, DbType.String, size: 20);
        parameters.Add("@PriceListName", priceList.PriceListName, DbType.String, size: 100);
        parameters.Add("@CurrencyId", priceList.CurrencyId, DbType.Int32);
        parameters.Add("@Description", priceList.Description, DbType.String, size: 500);
        parameters.Add("@IsActive", priceList.IsActive, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_PriceList_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            priceList.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateAsync(
        PriceList priceList, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", priceList.Id, DbType.Int32);
        parameters.Add("@PriceListCode", priceList.PriceListCode, DbType.String, size: 20);
        parameters.Add("@PriceListName", priceList.PriceListName, DbType.String, size: 100);
        parameters.Add("@CurrencyId", priceList.CurrencyId, DbType.Int32);
        parameters.Add("@Description", priceList.Description, DbType.String, size: 500);
        parameters.Add("@IsActive", priceList.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_PriceList_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetActiveAsync(
        int id, bool isActive, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_PriceList_SetActive", new { Id = id, IsActive = isActive, UserId = userId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_PriceList_Delete", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<PriceListLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<PriceListLookup>(new CommandDefinition(
                "masterdata.usp_PriceList_Lookup", new { ActiveOnly = activeOnly, IncludeId = includeId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- helpers -----

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "PriceListCode";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";

    public async Task<UnitPriceResolutionDto?> ResolveUnitPriceAsync(
        int itemUnitId, int priceListId, int? branchId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var row = await connection.QueryFirstOrDefaultAsync<ResolvedPriceRow>(new CommandDefinition(
            "masterdata.usp_UnitPrice_Resolve",
            new { ItemUnitId = itemUnitId, PriceListId = priceListId, BranchId = branchId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return row is null
            ? null
            : new UnitPriceResolutionDto
            {
                ItemUnitId = row.ItemUnitId,
                PriceListId = row.PriceListId,
                Price = row.Price,
                Source = row.PriceSource,
                CurrencyCode = row.CurrencyCode,
                DecimalPlaces = row.DecimalPlaces,
                BranchName = row.BranchName,
            };
    }

    /// <summary>The columns usp_UnitPrice_Resolve answers with; the rest of its row is not needed here.</summary>
    private sealed class ResolvedPriceRow
    {
        public int ItemUnitId { get; init; }
        public int PriceListId { get; init; }
        public decimal Price { get; init; }
        public string PriceSource { get; init; } = string.Empty;
        public string CurrencyCode { get; init; } = string.Empty;
        public byte DecimalPlaces { get; init; }
        public string BranchName { get; init; } = string.Empty;
    }
}
