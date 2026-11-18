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

    /// <summary>
    /// The fourteen result sets of the procedure, read in its order (see the header of script 68), then the charts,
    /// the warehouse levels (91), the cards (115) and the insights (116) when asked.
    /// </summary>
    public async Task<DashboardSummaryDto> GetSummaryAsync(
        int? branchId, DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo, DateTime today,
        bool includeWarehouseLevels, bool includeCards, bool includeInsights, CancellationToken cancellationToken = default)
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

        // (91) "Warehouse levels below Min": a third, small procedure, so the summary is not re-created for one figure -
        // read only for a reader who may see it (the service decides): it reads every level of the scope.
        if (includeWarehouseLevels && summary.StockAlerts is not null)
        {
            summary.StockAlerts.BelowWarehouseMin = await connection.QuerySingleOrDefaultAsync<int?>(new CommandDefinition(
                "reporting.usp_Dashboard_StockLevels", new { BranchId = branchId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken)) ?? 0;
        }

        // (115) The cards: a fourth procedure, read only when the reader may see at least one of them (the service decides).
        if (includeCards)
        {
            using var cards = await connection.QueryMultipleAsync(new CommandDefinition(
                "reporting.usp_Dashboard_Cards",
                new { BranchId = branchId, From = from.Date, To = to.Date, Today = today.Date },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            summary.ContainerStages = (await cards.ReadAsync<DashboardStageDto>()).AsList();
            summary.PayablesDetail = await cards.ReadSingleAsync<DashboardPayablesDetailDto>();
            summary.Creditors = (await cards.ReadAsync<DashboardCreditorDto>()).AsList();
            summary.ReceivablesAging = await cards.ReadSingleAsync<DashboardReceivablesAgingDto>();
            summary.Debtors = (await cards.ReadAsync<DashboardDebtorDto>()).AsList();
            summary.PurchasesByMonth = (await cards.ReadAsync<DashboardPurchaseMonthDto>()).AsList();
        }

        // (116) The insights: a fifth procedure, its twelve result sets in its order, read only when the reader may see
        // at least one of them (the service decides, and removes the others).
        if (includeInsights)
        {
            using var insights = await connection.QueryMultipleAsync(new CommandDefinition(
                "reporting.usp_Dashboard_Insights",
                new { BranchId = branchId, From = from.Date, To = to.Date, Today = today.Date },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            summary.TopItems = (await insights.ReadAsync<DashboardTopItemDto>()).AsList();
            summary.TopCustomers = (await insights.ReadAsync<DashboardTopCustomerDto>()).AsList();
            summary.SalesByBranch = (await insights.ReadAsync<DashboardBranchSalesDto>()).AsList();
            summary.CashAccounts = (await insights.ReadAsync<DashboardCashAccountDto>()).AsList();
            summary.Transfers = await insights.ReadSingleAsync<DashboardTransfersDto>();
            summary.Transfers.List = (await insights.ReadAsync<DashboardTransferDto>()).AsList();
            summary.SlowStock = await insights.ReadSingleAsync<DashboardSlowStockDto>();
            summary.SlowStock.List = (await insights.ReadAsync<DashboardSlowItemDto>()).AsList();
            summary.ChargesMissing = await insights.ReadSingleAsync<DashboardChargesMissingDto>();
            summary.ChargesMissing.ByType = (await insights.ReadAsync<DashboardChargeTypeCoverDto>()).AsList();
            summary.ChargesMissing.List = (await insights.ReadAsync<DashboardUnchargedContainerDto>()).AsList();
            summary.LeadTimes = new DashboardLeadTimesDto
            {
                Suppliers = (await insights.ReadAsync<DashboardSupplierLeadTimeDto>()).AsList(),
            };
        }

        return summary;
    }
}
