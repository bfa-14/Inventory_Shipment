using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Receipts;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Customer receipts. Each write needs its own permission (checked here and on the controller),
/// because they are different rights: the person who may type a draft is not necessarily the one who
/// may post it, reverse it, or apply its credit to invoices.
///
/// A RECEIPT IS ALWAYS RETURNED WHOLE. Save, post, reverse and allocate answer with the re-read
/// receipt: posting moves the status and starts paying invoices, and a client that had to guess which
/// of those happened would be reimplementing the procedure.
/// </summary>
public interface IReceiptService
{
    Task<Result<PagedResult<ReceiptListDto>>> SearchAsync(ReceiptQuery query, CancellationToken cancellationToken = default);

    Task<Result<ReceiptDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates a draft. Needs sales.receipts.create.</summary>
    Task<Result<ReceiptDto>> SaveDraftAsync(
        int? id, SaveReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Needs sales.receipts.post. Refuses an unbalanced receipt (UNBALANCED) or an over-allocated invoice.</summary>
    Task<Result<ReceiptDto>> PostAsync(
        int id, PostReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Needs sales.receipts.reverse. A Free Receipt already applied to invoices answers HAS_ALLOCATIONS.</summary>
    Task<Result<ReceiptDto>> ReverseAsync(
        int id, ReverseReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Drafts only. Needs sales.receipts.delete.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Applies the unapplied credit of a posted Free Receipt to invoices. Needs sales.receipts.allocate.</summary>
    Task<Result<ReceiptDto>> AllocateAsync(
        int id, AllocateReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Takes back a later allocation. Needs sales.receipts.allocate.</summary>
    Task<Result<ReceiptDto>> DeallocateAsync(
        int id, int allocationId, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The customer's posted sales invoices with something left to pay.</summary>
    Task<Result<IReadOnlyList<OpenInvoiceDto>>> OpenInvoicesAsync(int clientId, CancellationToken cancellationToken = default);

    /// <summary>The customer's ledger for a period (whole history when no dates are given).</summary>
    Task<Result<CustomerStatementDto>> StatementAsync(int clientId, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default);

    /// <summary>The rate a payment line pre-fills. Rate is null when none is defined - a warning, not an error.</summary>
    Task<Result<ReceiptRateDto>> ResolveRateAsync(int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    /// <summary>Returns the new file's id. Needs sales.receipts.create.</summary>
    Task<Result<int>> AddFileAsync(
        int receiptId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The files with their type, date and note, newest first; one type when asked.</summary>
    Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int receiptId, int? attachmentTypeId, CancellationToken cancellationToken = default);

    /// <summary>The type, date and note of a file (not on a reversed receipt). Needs sales.receipts.create.</summary>
    Task<Result<DocumentFileDto>> UpdateFileAsync(
        int receiptId, int fileId, DocumentFileFields fields, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ReceiptFileContent>> GetFileAsync(int receiptId, int fileId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only. Needs sales.receipts.create.</summary>
    Task<Result> DeleteFileAsync(
        int receiptId, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
