using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>Purchase charge types (US-MD-008). Every write throws a <c>BusinessRuleException</c> numbered 68xxx.</summary>
public interface IChargeTypeRepository
{
    Task<(IReadOnlyList<ChargeTypeDto> Items, int TotalCount)> SearchAsync(
        ChargeTypeQuery query, CancellationToken cancellationToken = default);

    /// <summary>For a charge line's dropdown. <paramref name="includeId"/> keeps a deactivated type visible on a document that uses it.</summary>
    Task<IReadOnlyList<ChargeTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default);

    Task<ChargeTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveChargeTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a type no charge line has ever used; otherwise 68005.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
