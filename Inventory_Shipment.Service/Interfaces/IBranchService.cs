using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IBranchService
{
    Task<Result<PagedResult<BranchDto>>> SearchAsync(BranchQuery query, CancellationToken cancellationToken = default);

    Task<Result<BranchDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The active main branch, or NotFound when no branch carries the flag.</summary>
    Task<Result<BranchDto>> GetMainAsync(CancellationToken cancellationToken = default);

    Task<Result<BranchDto>> CreateAsync(SaveBranchRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<BranchDto>> UpdateAsync(int id, SaveBranchRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<BranchDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Branches for a Branch / Site dropdown; <paramref name="includeId"/> keeps one inactive branch visible.</summary>
    Task<Result<IReadOnlyList<BranchLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
