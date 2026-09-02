using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IBrandService
{
    Task<Result<PagedResult<BrandDto>>> SearchAsync(BrandQuery query, CancellationToken cancellationToken = default);

    Task<Result<BrandDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<BrandDto>> CreateAsync(SaveBrandRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<BrandDto>> UpdateAsync(int id, SaveBrandRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<BrandDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Brands for a Brand dropdown; <paramref name="includeId"/> keeps one inactive brand visible.</summary>
    Task<Result<IReadOnlyList<BrandLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
