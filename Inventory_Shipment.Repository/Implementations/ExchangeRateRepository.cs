using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ExchangeRateRepository : IExchangeRateRepository
{
    /// <summary>Columns the search procedure accepts; anything else falls back to RateDate.</summary>
    private static readonly string[] SortColumns =
        ["RateDate", "CurrencyCode", "RateType", "Rate", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ExchangeRateRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape the search procedure returns: the joined columns plus the windowed total.</summary>
    private sealed class ExchangeRateRow
    {
        public int Id { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public string CurrencyName { get; init; } = string.Empty;
        public string? Symbol { get; init; }
        public byte DecimalPlaces { get; init; }
        public byte RateType { get; init; }
        public DateTime RateDate { get; init; }
        public decimal Rate { get; init; }
        public string? Notes { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public ExchangeRate ToExchangeRate() => new()
        {
            Id = Id,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            CurrencyName = CurrencyName,
            Symbol = Symbol,
            DecimalPlaces = DecimalPlaces,
            RateType = (Model.Enums.RateType)RateType,
            RateDate = RateDate,
            Rate = Rate,
            Notes = Notes,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            UpdatedAtUtc = UpdatedAtUtc,
            UpdatedBy = UpdatedBy,
            RowVersion = RowVersion
        };
    }

    public async Task<(IReadOnlyList<ExchangeRate> Items, int TotalCount)> SearchAsync(
        ExchangeRateQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@CurrencyId", query.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", (byte?)query.RateType, DbType.Byte);
        parameters.Add("@DateFrom", ToDateTime(query.DateFrom), DbType.Date);
        parameters.Add("@DateTo", ToDateTime(query.DateTo), DbType.Date);
        parameters.Add("@SortColumn", ResolveSortColumn(query.SortBy), DbType.String, size: 30);
        parameters.Add("@SortDirection", ResolveSortDirection(query.SortDir), DbType.String, size: 4);
        parameters.Add("@PageNumber", query.Page, DbType.Int32);
        parameters.Add("@PageSize", query.PageSize, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ExchangeRateRow>(new CommandDefinition(
                "masterdata.usp_ExchangeRate_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats the same COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToExchangeRate()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<ExchangeRate?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var row = await connection.QuerySingleOrDefaultAsync<ExchangeRateRow>(new CommandDefinition(
                "masterdata.usp_ExchangeRate_Get", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return row?.ToExchangeRate();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<ExchangeRate>> GetLatestAsync(
        int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@CurrencyId", currencyId, DbType.Int32);
        parameters.Add("@AsOfDate", ToDateTime(asOfDate), DbType.Date);

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ExchangeRateRow>(new CommandDefinition(
                "masterdata.usp_ExchangeRate_GetLatest", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.Select(r => r.ToExchangeRate()).ToList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> CreateAsync(
        ExchangeRate rate, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@CurrencyId", rate.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", (byte)rate.RateType, DbType.Byte);
        parameters.Add("@RateDate", rate.RateDate, DbType.Date);
        parameters.Add("@Rate", rate.Rate, DbType.Decimal, precision: 18, scale: 6);
        parameters.Add("@Notes", rate.Notes, DbType.String, size: 300);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_ExchangeRate_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            rate.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateAsync(
        ExchangeRate rate, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", rate.Id, DbType.Int32);
        parameters.Add("@CurrencyId", rate.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", (byte)rate.RateType, DbType.Byte);
        parameters.Add("@RateDate", rate.RateDate, DbType.Date);
        parameters.Add("@Rate", rate.Rate, DbType.Decimal, precision: 18, scale: 6);
        parameters.Add("@Notes", rate.Notes, DbType.String, size: 300);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_ExchangeRate_Update", parameters,
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
                "masterdata.usp_ExchangeRate_Delete", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- helpers -----

    /// <summary>A DATE parameter: SqlClient binds DateTime, so the DateOnly is widened at midnight.</summary>
    private static DateTime? ToDateTime(DateOnly? date)
        => date?.ToDateTime(TimeOnly.MinValue);

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "RateDate";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC";
}
