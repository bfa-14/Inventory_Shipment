using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>What the stock is worth, and what selling it earned.</summary>
public interface ICostingReportService
{
    /// <summary>Needs inventory.items.view: a valuation is the item list with its money shown.</summary>
    Task<Result<InventoryValuationResult>> ValuationAsync(
        int? warehouseId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportValuationAsync(
        int? warehouseId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Needs sales.profit.view.</summary>
    Task<Result<IReadOnlyList<SalesProfitRowDto>>> SalesProfitAsync(
        SalesProfitQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportSalesProfitAsync(
        SalesProfitQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
