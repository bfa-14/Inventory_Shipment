using Inventory_Shipment.Model.DTOs.Documents;
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
        int paymentId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>The files of a payment (one with fileId) with their type, date and note, newest first.</summary>
    Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int paymentId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default);

    Task<PaymentFileContent?> GetFileAsync(int paymentId, int fileId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Name, type, date and note of a file and, when content is given, its bytes; answers the file's row (null: not this
    /// payment's). Not on a reversed payment (73005).
    /// </summary>
    Task<DocumentFileDto?> UpdateFileAsync(
        int paymentId, int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int paymentId, int fileId, int userId, CancellationToken cancellationToken = default);
}
