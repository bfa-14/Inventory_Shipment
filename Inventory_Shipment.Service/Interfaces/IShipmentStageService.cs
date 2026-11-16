using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>(111) Shipment stages: kept by an administrator, and the way a container moves on.</summary>
public interface IShipmentStageService
{
    Task<Result<IReadOnlyList<ShipmentStageDto>>> ListAsync(
        bool activeOnly, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ShipmentStageDto>> SaveAsync(
        int? id, SaveShipmentStageRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ShipmentStageCheckDto>> CheckAsync(IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<ShipmentStagePreviewRowDto>>> PreviewAsync(
        ShipmentStagePreviewRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<ShipmentStageMatchRowDto>>> MatchNumbersAsync(
        ShipmentStageMatchRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ApplyShipmentStageResultDto>> ApplyAsync(
        ApplyShipmentStageRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
