using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>Script 97: a BIVAC item's cost per port, and the BIVAC items a charge on some containers may name.</summary>
public interface IBivacCostService
{
    Task<Result<IReadOnlyList<ItemBivacPortCostDto>>> GetPortCostsAsync(int itemId, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<ItemBivacPortCostDto>>> SetPortCostsAsync(
        int itemId, SetItemBivacPortCostsRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<BivacChargeOptionsDto>> GetChargeOptionsAsync(
        IReadOnlyCollection<int> containerIds, CancellationToken cancellationToken = default);
}
