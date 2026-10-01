using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>Read-only access to sales.OutOfStockSaleAudit. The rows are written by the invoice post itself.</summary>
public interface IOutOfStockAuditRepository
{
    Task<(IReadOnlyList<OutOfStockAuditDto> Items, int TotalCount)> SearchAsync(
        OutOfStockAuditQuery query, CancellationToken cancellationToken = default);
}
