using Inventory_Shipment.Model.DTOs.Dashboard;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IDashboardRepository
{
    /// <summary>
    /// reporting.usp_Dashboard_Summary - every section, unfiltered; the service hides what the reader may not see.
    /// (91) <paramref name="includeWarehouseLevels"/>: also read reporting.usp_Dashboard_StockLevels ("Warehouse levels
    /// below Min"), only for a reader who may see it - the figure reads every level, so nobody else pays for it.
    /// (115) <paramref name="includeCards"/>: also read reporting.usp_Dashboard_Cards (containers by stage, payables and
    /// receivables in detail, purchases by month), only for a reader who may see at least one of them.
    /// </summary>
    Task<DashboardSummaryDto> GetSummaryAsync(
        int? branchId, DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo, DateTime today,
        bool includeWarehouseLevels, bool includeCards, CancellationToken cancellationToken = default);
}
