using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Payment methods for the receipt page. Writes need the manage permission (checked here and on the
/// controller); the lookup is open to any signed-in user because the receipt page reads it.
/// </summary>
public interface IPaymentMethodService
{
    Task<Result<PagedResult<PaymentMethodDto>>> SearchAsync(PaymentMethodQuery query, CancellationToken cancellationToken = default);

    Task<Result<PaymentMethodDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<PaymentMethodLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    Task<Result<PaymentMethodDto>> SaveAsync(
        int? id, SavePaymentMethodRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PaymentMethodDto>> SetActiveAsync(
        int id, SetReceiptMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Only a method nothing uses; otherwise IN_USE (409), and the page offers to deactivate it instead.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
