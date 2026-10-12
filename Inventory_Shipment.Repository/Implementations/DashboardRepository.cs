using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Dashboard;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class DashboardRepository : IDashboardRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public DashboardRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The fourteen result sets of the procedure, read in its order (see the header of script 68).</summary>
    public async Task<DashboardSummaryDto> GetSummaryAsync(
        int? branchId, DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo, DateTime today,
        CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "reporting.usp_Dashboard_Summary",
            new
            {
                BranchId = branchId,
                From = from.Date,
                To = to.Date,
                PrevFrom = prevFrom.Date,
                PrevTo = prevTo.Date,
                Today = today.Date,
            },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var summary = new DashboardSummaryDto
        {
            From = from.Date,
            To = to.Date,
            PrevFrom = prevFrom.Date,
            PrevTo = prevTo.Date,
            Today = today.Date,
            Sales = await multi.ReadSingleAsync<DashboardSalesDto>(),
            Receivables = await multi.ReadSingleAsync<DashboardReceivablesDto>(),
            Payables = await multi.ReadSingleAsync<DashboardPayablesDto>(),
            Inventory = await multi.ReadSingleAsync<DashboardInventoryDto>(),
            OnTheWay = await multi.ReadSingleAsync<DashboardOnTheWayDto>(),
            Drafts = (await multi.ReadAsync<DashboardDraftDto>()).AsList(),
            StockAlerts = await multi.ReadSingleAsync<DashboardStockAlertsDto>(),
            BelowMinimum = (await multi.ReadAsync<DashboardBelowMinimumDto>()).AsList(),
            Containers = await multi.ReadSingleAsync<DashboardContainersDto>(),
            ContainerList = (await multi.ReadAsync<DashboardContainerDto>()).AsList(),
            OverdueInvoices = (await multi.ReadAsync<DashboardOverdueInvoiceDto>()).AsList(),
            Cheques = await multi.ReadSingleAsync<DashboardChequesDto>(),
            ChequeList = (await multi.ReadAsync<DashboardChequeDto>()).AsList(),
            BaseCurrencyCode = await multi.ReadSingleOrDefaultAsync<string?>(),
        };

        // The charts: a second procedure, so the figures above stay readable on their own.
        using var charts = await connection.QueryMultipleAsync(new CommandDefinition(
            "reporting.usp_Dashboard_Charts",
            new { BranchId = branchId, From = from.Date, To = to.Date },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        summary.Trend = (await charts.ReadAsync<DashboardTrendMonthDto>()).AsList();
        summary.SalesByFamily = (await charts.ReadAsync<DashboardSliceDto>()).AsList();
        summary.StockByWarehouse = (await charts.ReadAsync<DashboardSliceDto>()).AsList();
        summary.SalesByWeekday = (await charts.ReadAsync<DashboardWeekdayDto>()).AsList();
        return summary;
    }
}
