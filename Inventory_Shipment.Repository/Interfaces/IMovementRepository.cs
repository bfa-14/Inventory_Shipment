using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Shipment movements over the logistics.usp_Movement_* procedures. Every write throws a
/// <c>BusinessRuleException</c> numbered 70xxx; the message is the procedure's.
/// </summary>
public interface IMovementRepository
{
    Task<(IReadOnlyList<MovementListDto> Items, int TotalCount)> SearchAsync(
        MovementQuery query, CancellationToken cancellationToken = default);

    /// <summary>The four result sets of logistics.usp_Movement_Get; null when there is no such movement.</summary>
    Task<MovementDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null, the number MOV-yyyy-nnnnnn is assigned now) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveMovementRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Start, Complete or Cancel: the containers' status, dates and location follow.</summary>
    Task SetStatusAsync(
        int id, string action, DateOnly? date, string? reason, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// purchase.usp_GoodsReceipt_CreateForMovement (script 64): a draft goods receipt for each eligible container of a
    /// COMPLETED Delivery-stage movement, each in its own transaction - one row per container, created or skipped with the
    /// reason. Called after <see cref="SetStatusAsync"/> has committed the completion, never inside a transaction (63010).
    /// 70006 / 70010 for a movement not found, not completed or not of the Delivery stage.
    /// </summary>
    Task<IReadOnlyList<MovementReceiptResultDto>> CreateGoodsReceiptsAsync(
        int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Planned only (70005 otherwise).</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// One movement for the chosen containers (logistics.usp_Movement_ShipContainers), in one transaction; the movement row.
    /// confirmDrafts is the one the service allows, not the request's.
    /// </summary>
    Task<ShippedMovementDto> ShipContainersAsync(
        ShipContainersRequest request, bool confirmDrafts, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// (81) logistics.usp_Container_NextStepPreview: the next step of each container (an unknown id too, Found false),
    /// the groups that can move on together and the ones that cannot, by reason. canConfirm: the reader holds
    /// containers.confirm (a draft that never moved can ship only then).
    /// </summary>
    Task<NextStepPreviewDto> NextStepPreviewAsync(
        IEnumerable<int> containerIds, bool canConfirm, CancellationToken cancellationToken = default);

    /// <summary>
    /// (81) logistics.usp_Movement_AddLeg: a new leg for a group of containers from where they are, started or planned,
    /// one movement or one per container, through usp_Movement_Save and usp_Movement_SetStatus - all or nothing, the
    /// refusal naming the container. One row per movement made.
    /// </summary>
    Task<IReadOnlyList<AddedLegDto>> AddLegAsync(
        AddLegCommand command, bool confirmDrafts, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// logistics.usp_Movement_ContainerCandidates: one page (at most 200) and the count across the pages.
    /// 70006 / 70005 for a movement not found or no longer editable, 70000 without a From.
    /// </summary>
    Task<(IReadOnlyList<MovementContainerCandidateDto> Items, int TotalCount)> ContainerCandidatesAsync(
        MovementContainerCandidateQuery query, int page, int pageSize, CancellationToken cancellationToken = default);

    /// <summary>(80) logistics.usp_Movement_JoinCandidates: the planned movements the container can join, newest first. 70006 without it.</summary>
    Task<IReadOnlyList<MovementJoinCandidateDto>> JoinCandidatesAsync(int containerId, CancellationToken cancellationToken = default);

    /// <summary>
    /// logistics.usp_Movement_MatchContainers: one row per non-empty number, rowNo = its position in the list
    /// from 1. 70000 above 500 numbers.
    /// </summary>
    Task<IReadOnlyList<MovementContainerMatchDto>> MatchContainersAsync(
        int? movementId, int fromPlaceId, IReadOnlyList<string?> numbers, int? toPlaceId = null, int? movementTypeId = null,
        CancellationToken cancellationToken = default);
}
