using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>The log of out-of-stock sales users confirmed. Read-only; the controller holds the view permission.</summary>
public interface IOutOfStockAuditService
{
    Task<Result<PagedResult<OutOfStockAuditDto>>> SearchAsync(OutOfStockAuditQuery query, CancellationToken cancellationToken = default);
}
