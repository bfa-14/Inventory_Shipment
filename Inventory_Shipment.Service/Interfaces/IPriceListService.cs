using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IPriceListService
{
    Task<Result<PagedResult<PriceListDto>>> SearchAsync(PriceListQuery query, CancellationToken cancellationToken = default);

    Task<Result<PriceListDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<PriceListDto>> CreateAsync(SavePriceListRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<PriceListDto>> UpdateAsync(int id, SavePriceListRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<PriceListDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Price lists for a Price List dropdown; <paramref name="includeId"/> keeps one inactive list visible.</summary>
    Task<Result<IReadOnlyList<PriceListLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
