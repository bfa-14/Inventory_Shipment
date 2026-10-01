using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

public sealed class OutOfStockAuditService : IOutOfStockAuditService
{
    private readonly IOutOfStockAuditRepository _audit;

    public OutOfStockAuditService(IOutOfStockAuditRepository audit)
    {
        _audit = audit;
    }

    public async Task<Result<PagedResult<OutOfStockAuditDto>>> SearchAsync(
        OutOfStockAuditQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _audit.SearchAsync(query, cancellationToken);

        return Result<PagedResult<OutOfStockAuditDto>>.Success(new PagedResult<OutOfStockAuditDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }
}
