using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>The shortage report, inventory.usp_Shortage_Report: what is below its minimum, and what to order.</summary>
public interface IShortageRepository
{
    /// <summary>Not paged: the report is read whole, filtered and sorted on the page, and summed for its cards.</summary>
    Task<IReadOnlyList<ShortageRowDto>> ReportAsync(ShortageQuery query, CancellationToken cancellationToken = default);
}
