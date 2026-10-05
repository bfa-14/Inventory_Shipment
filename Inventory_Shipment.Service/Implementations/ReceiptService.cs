using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.ReceiptRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ReceiptService : IReceiptService
{
    private const string NotFoundMessage = "Receipt not found.";

    private readonly IReceiptRepository _receipts;
    private readonly ILogger<ReceiptService> _logger;

    public ReceiptService(IReceiptRepository receipts, ILogger<ReceiptService> logger)
    {
        _receipts = receipts;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<ReceiptListDto>>> SearchAsync(ReceiptQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _receipts.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ReceiptListDto>>.Success(new PagedResult<ReceiptListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<ReceiptDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var receipt = await _receipts.GetAsync(id, cancellationToken);
        return receipt is null
            ? Result<ReceiptDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ReceiptDto>.Success(receipt);
    }

    public async Task<Result<IReadOnlyList<OpenInvoiceDto>>> OpenInvoicesAsync(int clientId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<OpenInvoiceDto>>.Success(await _receipts.OpenInvoicesAsync(clientId, cancellationToken));

    public async Task<Result<CustomerStatementDto>> StatementAsync(int clientId, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default)
    {
        try
        {
            return Result<CustomerStatementDto>.Success(await _receipts.StatementAsync(clientId, from, to, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<CustomerStatementDto>(ex);
        }
    }

    public async Task<Result<ReceiptRateDto>> ResolveRateAsync(int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        var rate = await _receipts.ResolveRateAsync(currencyId, asOfDate, cancellationToken);

        // No row means no such currency - that IS an error. A row with a null Rate is not: it is the
        // ordinary "no rate published for that date", which the page shows as a warning.
        return rate is null
            ? Result<ReceiptRateDto>.Failure(ErrorType.NotFound, "Currency not found.", "NOT_FOUND")
            : Result<ReceiptRateDto>.Success(rate);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ReceiptDto>> SaveDraftAsync(
        int? id, SaveReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsCreate))
        {
            return Forbidden<ReceiptDto>(Permissions.Sales.ReceiptsCreate);
        }

        int savedId;
        try
        {
            savedId = await _receipts.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ReceiptDto>(ex);
        }

        _logger.LogInformation("Receipt {Id} saved as a draft by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<ReceiptDto>> PostAsync(
        int id, PostReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsPost))
        {
            return Forbidden<ReceiptDto>(Permissions.Sales.ReceiptsPost);
        }

        try
        {
            await _receipts.PostAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ReceiptDto>(ex);
        }

        _logger.LogInformation("Receipt {Id} posted by user {UserId}", id, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result<ReceiptDto>> ReverseAsync(
        int id, ReverseReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsReverse))
        {
            return Forbidden<ReceiptDto>(Permissions.Sales.ReceiptsReverse);
        }

        try
        {
            await _receipts.ReverseAsync(id, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ReceiptDto>(ex);
        }

        _logger.LogInformation("Receipt {Id} reversed by user {UserId}", id, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsDelete))
        {
            return Forbidden(Permissions.Sales.ReceiptsDelete);
        }

        try
        {
            await _receipts.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Receipt {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    public async Task<Result<ReceiptDto>> AllocateAsync(
        int id, AllocateReceiptRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsAllocate))
        {
            return Forbidden<ReceiptDto>(Permissions.Sales.ReceiptsAllocate);
        }

        try
        {
            await _receipts.AllocateAsync(id, request.Allocations, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ReceiptDto>(ex);
        }

        _logger.LogInformation("Receipt {Id}: {Count} invoice(s) allocated by user {UserId}", id, request.Allocations.Count, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result<ReceiptDto>> DeallocateAsync(
        int id, int allocationId, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsAllocate))
        {
            return Forbidden<ReceiptDto>(Permissions.Sales.ReceiptsAllocate);
        }

        // THE ALLOCATION MUST BELONG TO THE RECEIPT IN THE URL. The procedure takes the allocation id
        // alone, so without this check /receipts/7/allocations/99 would quietly remove an allocation
        // of receipt 3 and answer with receipt 7.
        var receipt = await _receipts.GetAsync(id, cancellationToken);
        if (receipt is null)
        {
            return Result<ReceiptDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        if (receipt.Allocations.All(a => a.Id != allocationId))
        {
            return Result<ReceiptDto>.Failure(ErrorType.NotFound, "Allocation not found on this receipt.", "NOT_FOUND");
        }

        try
        {
            await _receipts.DeallocateAsync(allocationId, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ReceiptDto>(ex);
        }

        _logger.LogInformation("Receipt {Id}: allocation {AllocationId} removed by user {UserId}", id, allocationId, userId);
        return await GetAsync(id, cancellationToken);
    }

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<int>> AddFileAsync(
        int receiptId, int? attachmentTypeId, string? note, string fileName, string contentType, byte[] content, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsCreate))
        {
            return Forbidden<int>(Permissions.Sales.ReceiptsCreate);
        }

        try
        {
            var fileId = await _receipts.AddFileAsync(
                receiptId, attachmentTypeId, note, fileName, contentType, content, userId, cancellationToken);
            return Result<int>.Success(fileId);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }
    }

    public async Task<Result<ReceiptFileContent>> GetFileAsync(int receiptId, int fileId, CancellationToken cancellationToken = default)
    {
        var file = await _receipts.GetFileAsync(receiptId, fileId, cancellationToken);
        return file is null
            ? Result<ReceiptFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<ReceiptFileContent>.Success(file);
    }

    public async Task<Result> UpdateFileAsync(
        int receiptId, int fileId, int? attachmentTypeId, string? note, string fileName, string? contentType, byte[]? content,
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsCreate))
        {
            return Forbidden(Permissions.Sales.ReceiptsCreate);
        }

        try
        {
            await _receipts.UpdateFileAsync(
                receiptId, fileId, attachmentTypeId, note, fileName, contentType, content, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        return Result.Success();
    }

    public async Task<Result> DeleteFileAsync(
        int receiptId, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ReceiptsCreate))
        {
            return Forbidden(Permissions.Sales.ReceiptsCreate);
        }

        try
        {
            await _receipts.DeleteFileAsync(receiptId, fileId, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        return Result.Success();
    }
}
