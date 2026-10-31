using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Shipment movements: one leg of the route carrying one or more containers. Reading needs
/// containers.view; everything else containers.movements.manage.
/// </summary>
public interface IMovementService
{
    Task<Result<PagedResult<MovementListDto>>> SearchAsync(
        MovementQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<MovementDto>> GetAsync(int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates a planned / in-progress movement.</summary>
    Task<Result<MovementDto>> SaveAsync(
        int? id, SaveMovementRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Planned → in progress: the containers move (in transit, at port... by the type's stage).</summary>
    Task<Result<MovementDto>> StartAsync(
        int id, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<MovementDto>> CompleteAsync(
        int id, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// (82) "Only some containers arrived": the ticked containers of a movement in progress leave it for their own movement
    /// (a copy: same header and start date), which is completed on the date - checked before anything is split; a Delivery
    /// drafts their goods receipts. The others stay on it, in progress. Ok false: split, but its completion was refused
    /// (the message says so). Needs containers.movements.manage.
    /// </summary>
    Task<Result<MovementSplitResultDto>> CompleteSomeAsync(
        int id, CompleteSomeContainersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Needs a reason.</summary>
    Task<Result<MovementDto>> CancelAsync(
        int id, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Planned movements only.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// One movement for the chosen containers, started at once unless startNow is false. Needs
    /// containers.movements.manage; the drafts are confirmed only for a caller with containers.confirm.
    /// </summary>
    Task<Result<ShippedMovementDto>> ShipContainersAsync(
        ShipContainersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// The containers a movement can take, for the From on the page (required): canAdd / reason are the checks of
    /// the save, the place rule included. Needs containers.movements.manage.
    /// </summary>
    Task<Result<PagedResult<MovementContainerCandidateDto>>> ContainerCandidatesAsync(
        MovementContainerCandidateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// (80) The planned movements a container can join ("Add to a movement..." on its page): after its latest movement and
    /// at its place, so the save will not refuse it for where it is. Needs containers.movements.manage.
    /// </summary>
    Task<Result<IReadOnlyList<MovementJoinCandidateDto>>> JoinCandidatesAsync(
        int containerId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Container numbers or refs matched for a movement, one row per number in order. Needs containers.movements.manage.</summary>
    Task<Result<IReadOnlyList<MovementContainerMatchDto>>> MatchContainersAsync(
        MatchMovementContainersRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// (81) The next step of one container (the container page's button, the dialog for one container): what it is, the
    /// movement it concerns with its RowVersion, the proposed new leg and the "Then" leg. Needs containers.view.
    /// </summary>
    Task<Result<ContainerNextStepDto>> GetNextStepAsync(
        int containerId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// (81) The "Next step..." dialog for ticked containers: one row each, the groups that move on together, the ones that
    /// cannot by reason. 1 to 5,000 containers. Needs containers.movements.manage.
    /// </summary>
    Task<Result<NextStepPreviewDto>> PreviewNextStepAsync(
        NextStepPreviewRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// (81) Applies each group on its own (one refusal never stops the others): Complete and Start through the movement's
    /// own Complete / Start (a Delivery drafts its goods receipts after the commit), a new leg through
    /// usp_Movement_AddLeg; the "Then" leg after a Complete as a second step, a warning when refused. Drafts are confirmed
    /// only with containers.confirm. Needs containers.movements.manage. One result per group, in order.
    /// </summary>
    Task<Result<IReadOnlyList<NextStepGroupResultDto>>> ApplyNextStepAsync(
        ApplyNextStepRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The filtered list (every page) as a workbook.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        MovementQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
