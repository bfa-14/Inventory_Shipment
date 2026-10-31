using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>Script 97: a BIVAC item's cost per port, and what a BIVAC charge on some containers would cost.</summary>
public interface IBivacCostRepository
{
    Task<IReadOnlyList<ItemBivacPortCostDto>> GetPortCostsAsync(int itemId, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<ItemBivacPortCostDto>> SetPortCostsAsync(
        int itemId, IReadOnlyList<ItemBivacPortCostRequest> costs, int userId, CancellationToken cancellationToken = default);

    Task<BivacChargeOptionsDto> GetChargeOptionsAsync(IReadOnlyCollection<int> containerIds, CancellationToken cancellationToken = default);
}
