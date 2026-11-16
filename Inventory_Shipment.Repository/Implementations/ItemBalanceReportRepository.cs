using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ItemBalanceReportRepository : IItemBalanceReportRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public ItemBalanceReportRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<ItemBalanceWarehouseDto>> WarehousesAsync(int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ItemBalanceWarehouseDto>(new CommandDefinition(
            "reporting.usp_ItemBalance_Warehouses", new { UserId = userId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<ItemBalanceData> DataAsync(
        int userId, IReadOnlyCollection<int> warehouseIds, IReadOnlyCollection<int> itemIds, IReadOnlyCollection<int> familyIds,
        DateOnly dateFrom, DateOnly dateTo, bool detail, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("UserId", userId, DbType.Int32);
        parameters.Add("WarehouseIds", warehouseIds.Count == 0 ? null : string.Join(',', warehouseIds), DbType.String);
        parameters.Add("ItemIds", itemIds.Count == 0 ? null : string.Join(',', itemIds), DbType.String);
        parameters.Add("FamilyIds", familyIds.Count == 0 ? null : string.Join(',', familyIds), DbType.String);
        // DbType.Date, not DateTime: the procedure's parameters are DATE.
        parameters.Add("DateFrom", dateFrom.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("DateTo", dateTo.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("Detail", detail, DbType.Boolean);

        // EVERY RUN READS THE LEDGER FROM ITS FIRST ROW (no snapshot): the long timeout of the batch calls.
        // A warehouse the user may not use is refused (50010), as a SecurityRuleException.
        try
        {
            await using var connection = _connectionFactory.Create();
            await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "reporting.usp_ItemBalance_Data", parameters,
                commandType: CommandType.StoredProcedure, commandTimeout: _connectionFactory.BatchCommandTimeout,
                cancellationToken: cancellationToken));

            return new ItemBalanceData
            {
                Items = (await grid.ReadAsync<ItemBalanceItemRow>()).AsList(),
                Warehouses = (await grid.ReadAsync<ItemBalanceWarehouseRow>()).AsList(),
                Events = (await grid.ReadAsync<ItemBalanceEventRow>()).AsList(),
                Ledger = (await grid.ReadAsync<ItemBalanceLedgerRow>()).AsList(),
            };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<(ItemBalanceCurrencyDto? Currency, IReadOnlyList<ItemBalanceRateRow> Rates)> RatesAsync(
        int currencyId, byte rateType, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("CurrencyId", currencyId, DbType.Int32);
        parameters.Add("RateType", rateType, DbType.Byte);
        parameters.Add("DateTo", dateTo.ToDateTime(TimeOnly.MinValue), DbType.Date);

        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "reporting.usp_ItemBalance_Rates", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var currency = await grid.ReadSingleOrDefaultAsync<ItemBalanceCurrencyDto>();
        var rates = (await grid.ReadAsync<ItemBalanceRateRow>()).AsList();
        return (currency, rates);
    }

    public async Task<int?> BaseCurrencyIdAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QueryFirstOrDefaultAsync<int?>(new CommandDefinition(
            "SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 ORDER BY Id",
            cancellationToken: cancellationToken));
    }

    public async Task LogRunAsync(int userId, string output, DateOnly dateFrom, DateOnly dateTo, int? currencyId, byte? rateType,
        string criteria, int rows, int durationMs, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("UserId", userId, DbType.Int32);
        parameters.Add("OutputKind", output, DbType.String);
        parameters.Add("DateFrom", dateFrom.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("DateTo", dateTo.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("CurrencyId", currencyId, DbType.Int32);
        parameters.Add("RateType", rateType, DbType.Byte);
        parameters.Add("Criteria", criteria, DbType.String);
        parameters.Add("RowsReturned", rows, DbType.Int32);
        parameters.Add("DurationMs", durationMs, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition(
            "reporting.usp_ItemBalance_LogRun", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }
}
