using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>The shortage report and the purchase orders it turns into.</summary>
public interface IShortageService
{
    Task<Result<IReadOnlyList<ShortageRowDto>>> ReportAsync(ShortageQuery query, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(ShortageQuery query, CancellationToken cancellationToken = default);

    /// <summary>
    /// One draft purchase order per supplier AND warehouse, each in the supplier's currency at the
    /// day's rate, each line priced at the item's last cost unless the user typed another.
    /// </summary>
    Task<Result<CreatePurchaseOrdersResult>> CreateOrdersAsync(
        CreatePurchaseOrdersFromShortagesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
