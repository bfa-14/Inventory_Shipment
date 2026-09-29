using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Container charges over the logistics.usp_ContainerCharge_* procedures. Every write throws a
/// <c>BusinessRuleException</c> numbered 70xxx; the message is the procedure's.
/// </summary>
public interface IContainerChargeRepository
{
    /// <summary>One page, the total count and the total (base) of the whole filter.</summary>
    Task<(IReadOnlyList<ContainerChargeListDto> Items, int TotalCount, decimal TotalAmountBase)> SearchAsync(
        ContainerChargeQuery query, CancellationToken cancellationToken = default);

    /// <summary>The four result sets of usp_ContainerCharge_Get; null when there is no such charge.</summary>
    Task<ContainerChargeDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>One draft per container (same GroupId when several); the created rows.</summary>
    Task<IReadOnlyList<ContainerChargeGroupMemberDto>> CreateAsync(
        CreateContainerChargeRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only.</summary>
    Task UpdateAsync(int id, UpdateContainerChargeRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>One draft (id, with its row version) or several (ids): all or nothing.</summary>
    Task PostAsync(int? id, IReadOnlyList<int> ids, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posted only; the cost is reversed when the container is already offloaded.</summary>
    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>The containers that can receive a copy of the charge (logistics.usp_ContainerCharge_CopyCandidates).</summary>
    Task<IReadOnlyList<ChargeCopyCandidateDto>> GetCopyCandidatesAsync(
        int chargeId, ChargeCopyCandidateQuery query, CancellationToken cancellationToken = default);

    /// <summary>One draft per container in the original's group, optionally posted at once; the created charges.</summary>
    Task<IReadOnlyList<CopiedContainerChargeDto>> CopyToContainersAsync(
        int chargeId, CopyContainerChargeRequest request, int userId, CancellationToken cancellationToken = default);
}
