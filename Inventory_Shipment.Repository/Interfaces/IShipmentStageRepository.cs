using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>(111) The shipment stages (logistics.ShipmentStages) and where the containers stand on them.</summary>
public interface IShipmentStageRepository
{
    Task<IReadOnlyList<ShipmentStageDto>> ListAsync(bool activeOnly, CancellationToken cancellationToken = default);

    Task<int> SaveAsync(int? id, SaveShipmentStageRequest request, int userId, CancellationToken cancellationToken = default);

    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>logistics.usp_ShipmentStage_Check: the containers per stage, and the ones not on a stage with their legs.</summary>
    Task<ShipmentStageCheckDto> CheckAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// logistics.usp_ShipmentStage_Preview: one row per id - what moving it to the stage does, or why it cannot.
    /// 70006 the stage not found, 70000 inactive.
    /// </summary>
    Task<IReadOnlyList<ShipmentStagePreviewRowDto>> PreviewAsync(
        int stageId, IReadOnlyCollection<int> containerIds, bool canConfirm, CancellationToken cancellationToken = default);

    /// <summary>logistics.usp_ShipmentStage_MatchNumbers: the container each number of the forwarder's list names.</summary>
    Task<IReadOnlyList<ShipmentStageMatchRowDto>> MatchNumbersAsync(
        IReadOnlyList<string?> numbers, CancellationToken cancellationToken = default);

    /// <summary>The draft goods receipt of each container that has one (the one a completed Delivery made).</summary>
    Task<IReadOnlyDictionary<int, int>> DraftReceiptsAsync(
        IReadOnlyCollection<int> containerIds, CancellationToken cancellationToken = default);
}
