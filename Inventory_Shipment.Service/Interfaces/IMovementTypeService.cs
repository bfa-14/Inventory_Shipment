using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Movement types for the movement pages. Writes need masterdata.movementtypes.manage (checked here
/// and on the controller); the lookup needs containers.view, checked on the controller.
/// </summary>
public interface IMovementTypeService
{
    Task<Result<PagedResult<MovementTypeDto>>> SearchAsync(MovementTypeQuery query, CancellationToken cancellationToken = default);

    Task<Result<MovementTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<MovementTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    Task<Result<MovementTypeDto>> SaveAsync(
        int? id, SaveMovementTypeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<MovementTypeDto>> SetActiveAsync(
        int id, SetLogisticsMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Only a type no movement uses; otherwise IN_USE (409), and the page offers to deactivate it instead.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
