using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Container types for the container pages. Writes need the manage permission (checked here and on the
/// controller); the lookup is open to any signed-in user because every container page reads it.
/// </summary>
public interface IContainerTypeService
{
    Task<Result<PagedResult<ContainerTypeDto>>> SearchAsync(ContainerTypeQuery query, CancellationToken cancellationToken = default);

    Task<Result<ContainerTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<ContainerTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    Task<Result<ContainerTypeDto>> SaveAsync(
        int? id, SaveContainerTypeRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ContainerTypeDto>> SetActiveAsync(
        int id, SetLogisticsMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Only a row nothing uses; otherwise IN_USE (409), and the page offers to deactivate it instead.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
