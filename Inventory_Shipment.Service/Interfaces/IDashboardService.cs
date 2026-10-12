using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Dashboard;

namespace Inventory_Shipment.Service.Interfaces;

public interface IDashboardService
{
    /// <summary>The Dashboard's figures, with every section the reader may not see left out (NULL).</summary>
    Task<Result<DashboardSummaryDto>> GetSummaryAsync(
        DashboardSummaryQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
