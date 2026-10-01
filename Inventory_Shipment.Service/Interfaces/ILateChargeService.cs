using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Late charges of a POSTED local purchase invoice: its landed cost adjustments, seen from the invoice.
///
/// EVERY WRITE GOES THROUGH <see cref="ILandedCostAdjustmentService"/>, so its permission checks and
/// its 67xxx classification apply unchanged. An imported invoice (from containers) and an invoice that
/// is not posted are refused here with 409, reads included.
/// </summary>
public interface ILateChargeService
{
    Task<Result<LateChargesDto>> GetAsync(
        int invoiceId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Into the invoice's open draft adjustment, created when there is none. Needs purchase.landedcosts.create.</summary>
    Task<Result<LateChargesDto>> AddAsync(
        int invoiceId, SaveLateChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>A charge of a DRAFT adjustment only. Needs purchase.landedcosts.create.</summary>
    Task<Result<LateChargesDto>> UpdateAsync(
        int invoiceId, int chargeId, SaveLateChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// A charge of a DRAFT adjustment only. Removing the last one deletes the empty adjustment, which
    /// also needs purchase.landedcosts.delete.
    /// </summary>
    Task<Result<LateChargesDto>> DeleteAsync(
        int invoiceId, int chargeId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Posts the open draft adjustment. Needs purchase.landedcosts.post.</summary>
    Task<Result<LateChargesPostedDto>> PostAsync(
        int invoiceId, PostLateChargesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Cancels a POSTED adjustment of the invoice. Needs purchase.landedcosts.cancel.</summary>
    Task<Result<LateChargesDto>> CancelAsync(
        int invoiceId, int adjustmentId, CancelLandedCostAdjustmentRequest request, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
