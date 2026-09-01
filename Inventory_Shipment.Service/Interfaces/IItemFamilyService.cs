using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IItemFamilyService
{
    /// <summary>Every family as a flat list (no paging - the client builds the tree from ParentId).</summary>
    Task<Result<IReadOnlyList<ItemFamilyDto>>> TreeAsync(CancellationToken cancellationToken = default);

    Task<Result<ItemFamilyDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Families for a dropdown; <paramref name="includeId"/> keeps one inactive family visible.</summary>
    Task<Result<IReadOnlyList<ItemFamilyLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    /// <summary>The code suggested for a new child of <paramref name="parentId"/> (null = a new root).</summary>
    Task<Result<NextCodeDto>> NextChildCodeAsync(int? parentId, CancellationToken cancellationToken = default);

    Task<Result<ItemFamilyDto>> CreateAsync(SaveItemFamilyRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<ItemFamilyDto>> UpdateAsync(int id, SaveItemFamilyRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Deactivating cascades to the whole subtree; activating fails when the parent is inactive.</summary>
    Task<Result<ItemFamilyDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);
}
