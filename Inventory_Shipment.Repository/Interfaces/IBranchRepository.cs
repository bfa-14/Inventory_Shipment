using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.Branches through its stored procedures. Every method turns a business-rule THROW
/// (51000-51006) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IBranchRepository
{
    /// <summary>masterdata.usp_Branch_Search - one page of branches plus the total row count.</summary>
    Task<(IReadOnlyList<Branch> Items, int TotalCount)> SearchAsync(
        BranchQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Branch_Get.</summary>
    Task<Branch?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Branch_GetMain - the active main branch, or null when there is none.</summary>
    Task<Branch?> GetMainAsync(CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Branch_Create - returns the new id. Throws 51000 / 51001 / 51002 / 51005.</summary>
    Task<int> CreateAsync(Branch branch, bool replaceMainBranch, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Branch_Update - throws 51000 / 51001 / 51002 / 51004 / 51005 / 51006.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(Branch branch, bool replaceMainBranch, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Branch_SetActive - throws 51005 (main branch) / 51006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Branch_Delete - throws 51003 (referenced) / 51005 (main branch) / 51006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Branch_Lookup - the branches a Branch / Site dropdown offers.
    /// <paramref name="includeId"/> keeps one extra branch in the list even when it is inactive, so an
    /// edit form can still show the branch the record currently points at.
    /// </summary>
    Task<IReadOnlyList<BranchLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
