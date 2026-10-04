using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>Supplier payments (purchase.usp_Payment_*). Every rule lives in the procedures; this only carries the calls.</summary>
public interface IPaymentRepository
{
    Task<(IReadOnlyList<PaymentListDto> Items, int TotalCount)> SearchAsync(PaymentQuery query, CancellationToken cancellationToken = default);

    Task<PaymentDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The payee's posted purchase invoices (PINV) or container charges (CHARGE) with something left to pay.</summary>
    Task<IReadOnlyList<OpenPayableDocumentDto>> OpenDocumentsAsync(
        int payeeId, string documentKind, int? paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate,
        CancellationToken cancellationToken = default);

    Task<PaymentRateDto?> RateToPaymentAsync(
        int fromCurrencyId, int paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    /// <returns>The id of the saved draft (a new one when <paramref name="id"/> is null).</returns>
    Task<int> SaveAsync(SavePaymentRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task ReverseAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    Task AllocateAsync(int id, IReadOnlyList<SavePaymentAllocationRequest> allocations, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task DeallocateAsync(int allocationId, int userId, CancellationToken cancellationToken = default);

    Task SetChequeStatusAsync(int lineId, byte clearanceStatus, int userId, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int paymentId, int? attachmentTypeId, string? note, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default);

    Task<PaymentFileContent?> GetFileAsync(int paymentId, int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int paymentId, int fileId, int userId, CancellationToken cancellationToken = default);
}
