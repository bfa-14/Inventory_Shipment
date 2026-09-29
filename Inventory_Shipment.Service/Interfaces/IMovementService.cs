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

    /// <summary>The filtered list (every page) as a workbook.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        MovementQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
