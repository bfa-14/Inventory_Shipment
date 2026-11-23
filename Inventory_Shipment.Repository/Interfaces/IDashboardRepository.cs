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
    /// (116) <paramref name="includeInsights"/>: also read reporting.usp_Dashboard_Insights (top items and customers, sales
    /// by branch, cash and bank, transfers on the way, slow stock, charges missing, lead times), on the same terms.
    /// (117) <paramref name="warehouseId"/>: only that warehouse and the warehouses under it, in each of the five procedures
    /// (script 117 says what that means per figure; receipts, payments and the company minimum are not narrowed).
    /// </summary>
    Task<DashboardSummaryDto> GetSummaryAsync(
        int? branchId, int? warehouseId, DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo, DateTime today,
        bool includeWarehouseLevels, bool includeCards, bool includeInsights, CancellationToken cancellationToken = default);
}
