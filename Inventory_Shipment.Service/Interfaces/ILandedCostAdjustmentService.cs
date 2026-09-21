using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Landed cost adjustments. Every action checks its own permission here as well as on the
/// controller, so the rule holds for any caller.
/// </summary>
public interface ILandedCostAdjustmentService
{
    Task<Result<PagedResult<LandedCostAdjustmentListDto>>> SearchAsync(
        LandedCostAdjustmentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<LandedCostAdjustmentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<LandedCostAdjustmentDto>> SaveDraftAsync(
        int? id, SaveLandedCostAdjustmentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<LandedCostAdjustmentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<LandedCostAdjustmentDto>> CancelAsync(
        int id, CancelLandedCostAdjustmentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The adjustment as a workbook: header block, the charges, and the split over the invoice lines.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
