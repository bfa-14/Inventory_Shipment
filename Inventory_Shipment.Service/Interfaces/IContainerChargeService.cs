using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Container charges: containers.charges.view to read, .create for drafts (create, edit, delete),
/// .post to post (the cost of the items moves), .cancel to cancel a posted one.
/// </summary>
public interface IContainerChargeService
{
    Task<Result<ContainerChargePageDto>> SearchAsync(
        ContainerChargeQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ContainerChargeDto>> GetAsync(int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>One draft per container; the created charges.</summary>
    Task<Result<IReadOnlyList<ContainerChargeGroupMemberDto>>> CreateAsync(
        CreateContainerChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerChargeDto>> UpdateAsync(
        int id, UpdateContainerChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerChargeDto>> PostAsync(
        int id, ChargeActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Several drafts, all or nothing; the posted charges.</summary>
    Task<Result<IReadOnlyList<ContainerChargeDto>>> PostManyAsync(
        PostChargesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerChargeDto>> CancelAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The filtered list (every page) with its total, as a workbook.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ContainerChargeQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
