using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// The two read-only reports that come out of the costing: what stock is worth, and what selling it
/// earned. Both read views and a procedure and write nothing.
/// </summary>
public interface ICostingReportRepository
{
    /// <summary>
    /// inventory.vw_InventoryValuation, or ...ByWarehouse when a warehouse is named. Not paged: the
    /// page sums and sorts the rows itself, and a total over one page would be a wrong total.
    /// </summary>
    Task<IReadOnlyList<InventoryValuationRowDto>> ValuationAsync(
        int? warehouseId, CancellationToken cancellationToken = default);

    /// <summary>sales.usp_SalesProfit_Report — one row per group, already summed in SQL.</summary>
    Task<IReadOnlyList<SalesProfitRowDto>> SalesProfitAsync(
        SalesProfitQuery query, CancellationToken cancellationToken = default);
}
