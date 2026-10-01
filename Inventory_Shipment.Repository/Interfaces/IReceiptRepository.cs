using Inventory_Shipment.Model.DTOs.Receipts;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// sales.Receipts and what hangs off it. Every write throws a <c>BusinessRuleException</c> numbered
/// 71xxx (or 64xxx where an invoice rule is involved) carrying the sentence the procedure wrote.
/// </summary>
public interface IReceiptRepository
{
    Task<(IReadOnlyList<ReceiptListDto> Items, int TotalCount)> SearchAsync(
        ReceiptQuery query, CancellationToken cancellationToken = default);

    /// <summary>The receipt whole - header, lines, allocations, files, audit - or null when there is none.</summary>
    Task<ReceiptDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates a DRAFT; returns the id. Lines and allocations are replaced, not merged.</summary>
    Task<int> SaveAsync(SaveReceiptRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Balance check (header = lines = allocations), then the invoices are locked and re-read.</summary>
    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task ReverseAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Applies the unapplied credit of a posted Free Receipt to invoices.</summary>
    Task AllocateAsync(
        int id, IReadOnlyList<SaveReceiptAllocationRequest> allocations, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>Takes back a later allocation. The row stays, stamped, as proof.</summary>
    Task DeallocateAsync(int allocationId, int userId, CancellationToken cancellationToken = default);

    /// <summary>A customer's posted sales invoices with something left to pay, oldest first.</summary>
    Task<IReadOnlyList<OpenInvoiceDto>> OpenInvoicesAsync(int clientId, CancellationToken cancellationToken = default);

    /// <summary>The customer's ledger; throws BusinessRuleException (not found) for an unknown customer.</summary>
    Task<CustomerStatementDto> StatementAsync(int clientId, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default);

    Task<ReceiptRateDto?> ResolveRateAsync(int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int receiptId, int? attachmentTypeId, string? note, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default);

    Task<ReceiptFileContent?> GetFileAsync(int receiptId, int fileId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only: the evidence of a posted payment stays.</summary>
    Task DeleteFileAsync(int receiptId, int fileId, int userId, CancellationToken cancellationToken = default);
}
