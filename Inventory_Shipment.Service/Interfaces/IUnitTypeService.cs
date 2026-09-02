using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IUnitTypeService
{
    Task<Result<PagedResult<UnitTypeDto>>> SearchAsync(UnitTypeQuery query, CancellationToken cancellationToken = default);

    Task<Result<UnitTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<UnitTypeDto>> CreateAsync(SaveUnitTypeRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<UnitTypeDto>> UpdateAsync(int id, SaveUnitTypeRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<UnitTypeDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Unit types for a dropdown; <paramref name="includeId"/> keeps one inactive unit type visible.</summary>
    Task<Result<IReadOnlyList<UnitTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
