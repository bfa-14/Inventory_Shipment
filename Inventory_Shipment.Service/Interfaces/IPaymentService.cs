using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Supplier payments (US-PAY-001). Each action that moves money has its own permission, checked here and
/// on the controller; every rule about the money itself is the database's (scripts 46-47).
/// </summary>
public interface IPaymentService
{
    Task<Result<PagedResult<PaymentListDto>>> SearchAsync(PaymentQuery query, CancellationToken cancellationToken = default);

    Task<Result<PaymentDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The payee's posted purchase invoices (PINV) or container charges (CHARGE) still owing something.</summary>
    Task<Result<IReadOnlyList<OpenPayableDocumentDto>>> OpenDocumentsAsync(
        int payeeId, string documentKind, int? paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate,
        CancellationToken cancellationToken = default);

    Task<Result<PaymentRateDto>> RateToPaymentAsync(
        int fromCurrencyId, int paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    Task<Result<PaymentDto>> SaveDraftAsync(
        int? id, SavePaymentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PaymentDto>> PostAsync(
        int id, PostPaymentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PaymentDto>> ReverseAsync(
        int id, ReversePaymentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PaymentDto>> AllocateAsync(
        int id, AllocatePaymentRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PaymentDto>> DeallocateAsync(
        int id, int allocationId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Pending / Cleared / Returned on a cheque line of a posted payment. Moves no money.</summary>
    Task<Result<PaymentDto>> SetChequeStatusAsync(
        int id, int lineId, SetChequeStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int paymentId, int? attachmentTypeId, string? note, string fileName, string contentType, byte[] content, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PaymentFileContent>> GetFileAsync(int paymentId, int fileId, CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(int paymentId, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
