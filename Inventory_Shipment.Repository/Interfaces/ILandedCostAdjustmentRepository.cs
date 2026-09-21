using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Landed cost adjustments: charges that arrive after the goods were received. Every write throws a
/// <c>BusinessRuleException</c> numbered 67xxx (or 65012 when a charge cannot be allocated).
/// </summary>
public interface ILandedCostAdjustmentRepository
{
    Task<(IReadOnlyList<LandedCostAdjustmentListDto> Items, int TotalCount)> SearchAsync(
        LandedCostAdjustmentQuery query, CancellationToken cancellationToken = default);

    /// <summary>Header, charges and the split over the invoice lines in one round trip.</summary>
    Task<LandedCostAdjustmentDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null — the number is assigned now) or replaces a draft; returns the id.</summary>
    Task<int> SaveAsync(
        SaveLandedCostAdjustmentRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
