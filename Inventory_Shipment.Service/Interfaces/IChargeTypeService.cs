using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>Purchase charge types (US-MD-008). One permission guards the lot: defining them is setup.</summary>
public interface IChargeTypeService
{
    Task<Result<PagedResult<ChargeTypeDto>>> SearchAsync(ChargeTypeQuery query, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<ChargeTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    Task<Result<ChargeTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<ChargeTypeDto>> SaveAsync(
        int? id, SaveChargeTypeRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<ChargeTypeDto>> SetActiveAsync(
        int id, SetChargeTypeActiveRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a type nothing has used; otherwise IN_USE, and the page offers to deactivate it instead.</summary>
    Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
