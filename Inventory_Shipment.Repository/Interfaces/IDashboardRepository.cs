using Inventory_Shipment.Model.DTOs.Dashboard;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IDashboardRepository
{
    /// <summary>
    /// reporting.usp_Dashboard_Summary - every section, unfiltered; the service hides what the reader may not see.
    /// (91) <paramref name="includeWarehouseLevels"/>: also read reporting.usp_Dashboard_StockLevels ("Warehouse levels
    /// below Min"), only for a reader who may see it - the figure reads every level, so nobody else pays for it.
    /// </summary>
    Task<DashboardSummaryDto> GetSummaryAsync(
        int? branchId, DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo, DateTime today,
        bool includeWarehouseLevels, CancellationToken cancellationToken = default);
}
