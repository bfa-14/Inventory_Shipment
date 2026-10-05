using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.PaymentRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class PaymentService : IPaymentService
{
    private const string NotFoundMessage = "Payment not found.";

    private readonly IPaymentRepository _payments;
    private readonly ILogger<PaymentService> _logger;

    public PaymentService(IPaymentRepository payments, ILogger<PaymentService> logger)
    {
        _payments = payments;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<PaymentListDto>>> SearchAsync(PaymentQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _payments.SearchAsync(query, cancellationToken);

        return Result<PagedResult<PaymentListDto>>.Success(new PagedResult<PaymentListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<PaymentDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var payment = await _payments.GetAsync(id, cancellationToken);
        return payment is null
            ? Result<PaymentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PaymentDto>.Success(payment);
    }

    public async Task<Result<IReadOnlyList<OpenPayableDocumentDto>>> OpenDocumentsAsync(
        int payeeId, string documentKind, int? paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate,
        CancellationToken cancellationToken = default)
    {
        var kind = documentKind?.Trim().ToUpperInvariant();
        if (kind is not (PaymentDocumentKinds.PurchaseInvoice or PaymentDocumentKinds.ContainerCharge))
        {
            return Result<IReadOnlyList<OpenPayableDocumentDto>>.Failure(
                ErrorType.Validation, "Document kind must be PINV or CHARGE.", "VALIDATION");
        }

        try
        {
            return Result<IReadOnlyList<OpenPayableDocumentDto>>.Success(
                await _payments.OpenDocumentsAsync(payeeId, kind, paymentCurrencyId, paymentRate, asOfDate, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<OpenPayableDocumentDto>>(ex);
        }
    }

    public async Task<Result<PaymentRateDto>> RateToPaymentAsync(
        int fromCurrencyId, int paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        var rate = await _payments.RateToPaymentAsync(fromCurrencyId, paymentCurrencyId, paymentRate, asOfDate, cancellationToken);

        // The row always comes back; a null RateToPayment in it is the ordinary "no rate published",
        // which the page shows as a warning and an editable box.
        return rate is null
            ? Result<PaymentRateDto>.Failure(ErrorType.NotFound, "Currency not found.", "NOT_FOUND")
            : Result<PaymentRateDto>.Success(rate);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PaymentDto>> SaveDraftAsync(
        int? id, SavePaymentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsCreate))
        {
            return Forbidden<PaymentDto>(Permissions.Purchase.PaymentsCreate);
        }

        int savedId;
        try
        {
            savedId = await _payments.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentDto>(ex);
        }

        _logger.LogInformation("Supplier payment {Id} saved as a draft by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<PaymentDto>> PostAsync(
        int id, PostPaymentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsPost))
        {
            return Forbidden<PaymentDto>(Permissions.Purchase.PaymentsPost);
        }

        try
        {
            await _payments.PostAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentDto>(ex);
        }

        _logger.LogInformation("Supplier payment {Id} posted by user {UserId}", id, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result<PaymentDto>> ReverseAsync(
        int id, ReversePaymentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsReverse))
        {
            return Forbidden<PaymentDto>(Permissions.Purchase.PaymentsReverse);
        }

        try
        {
            await _payments.ReverseAsync(id, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentDto>(ex);
        }

        _logger.LogInformation("Supplier payment {Id} reversed by user {UserId}", id, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsDelete))
        {
            return Forbidden(Permissions.Purchase.PaymentsDelete);
        }

        try
        {
            await _payments.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Supplier payment {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    public async Task<Result<PaymentDto>> AllocateAsync(
        int id, AllocatePaymentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsAllocate))
        {
            return Forbidden<PaymentDto>(Permissions.Purchase.PaymentsAllocate);
        }

        try
        {
            await _payments.AllocateAsync(id, request.Allocations, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentDto>(ex);
        }

        _logger.LogInformation("Supplier payment {Id}: {Count} document(s) allocated by user {UserId}", id, request.Allocations.Count, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result<PaymentDto>> DeallocateAsync(
        int id, int allocationId, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsAllocate))
        {
            return Forbidden<PaymentDto>(Permissions.Purchase.PaymentsAllocate);
        }

        // THE ALLOCATION MUST BELONG TO THE PAYMENT IN THE URL: the procedure takes the allocation id
        // alone, so without this /payments/7/allocations/99 would remove an allocation of payment 3.
        var payment = await _payments.GetAsync(id, cancellationToken);
        if (payment is null)
        {
            return Result<PaymentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        if (payment.Allocations.All(a => a.Id != allocationId))
        {
            return Result<PaymentDto>.Failure(ErrorType.NotFound, "Allocation not found on this payment.", "NOT_FOUND");
        }

        try
        {
            await _payments.DeallocateAsync(allocationId, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentDto>(ex);
        }

        _logger.LogInformation("Supplier payment {Id}: allocation {AllocationId} removed by user {UserId}", id, allocationId, userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result<PaymentDto>> SetChequeStatusAsync(
        int id, int lineId, SetChequeStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        /* Recording what the bank did with a cheque is part of keeping a payment, not of making one: the
           post permission, held by whoever runs the cash book. */
        if (!permissions.Contains(Permissions.Purchase.PaymentsPost))
        {
            return Forbidden<PaymentDto>(Permissions.Purchase.PaymentsPost);
        }

        var payment = await _payments.GetAsync(id, cancellationToken);
        if (payment is null)
        {
            return Result<PaymentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        if (payment.Lines.All(l => l.Id != lineId))
        {
            return Result<PaymentDto>.Failure(ErrorType.NotFound, "Payment line not found on this payment.", "NOT_FOUND");
        }

        try
        {
            await _payments.SetChequeStatusAsync(lineId, request.ClearanceStatus, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentDto>(ex);
        }

        _logger.LogInformation("Supplier payment {Id}: cheque line {LineId} set to {Status} by user {UserId}", id, lineId, request.ClearanceStatus, userId);
        return await GetAsync(id, cancellationToken);
    }

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<int>> AddFileAsync(
        int paymentId, int? attachmentTypeId, string? note, string fileName, string contentType, byte[] content, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsCreate))
        {
            return Forbidden<int>(Permissions.Purchase.PaymentsCreate);
        }

        try
        {
            var fileId = await _payments.AddFileAsync(paymentId, attachmentTypeId, note, fileName, contentType, content, userId, cancellationToken);
            return Result<int>.Success(fileId);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }
    }

    public async Task<Result<PaymentFileContent>> GetFileAsync(int paymentId, int fileId, CancellationToken cancellationToken = default)
    {
        var file = await _payments.GetFileAsync(paymentId, fileId, cancellationToken);
        return file is null
            ? Result<PaymentFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<PaymentFileContent>.Success(file);
    }

    public async Task<Result> UpdateFileAsync(
        int paymentId, int fileId, int? attachmentTypeId, string? note, string fileName, string? contentType, byte[]? content,
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsCreate))
        {
            return Forbidden(Permissions.Purchase.PaymentsCreate);
        }

        try
        {
            await _payments.UpdateFileAsync(
                paymentId, fileId, attachmentTypeId, note, fileName, contentType, content, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        return Result.Success();
    }

    public async Task<Result> DeleteFileAsync(
        int paymentId, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.PaymentsCreate))
        {
            return Forbidden(Permissions.Purchase.PaymentsCreate);
        }

        try
        {
            await _payments.DeleteFileAsync(paymentId, fileId, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        return Result.Success();
    }
}
