using Inventory_Shipment.Model.DTOs.Dashboard;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IDashboardRepository
{
    /// <summary>reporting.usp_Dashboard_Summary - every section, unfiltered; the service hides what the reader may not see.</summary>
    Task<DashboardSummaryDto> GetSummaryAsync(
        int? branchId, DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo, DateTime today,
        CancellationToken cancellationToken = default);
}
