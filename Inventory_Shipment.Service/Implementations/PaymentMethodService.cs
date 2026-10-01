using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.ReceiptRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class PaymentMethodService : IPaymentMethodService
{
    private const string NotFoundMessage = "Payment method not found.";

    private readonly IPaymentMethodRepository _items;
    private readonly ILogger<PaymentMethodService> _logger;

    public PaymentMethodService(IPaymentMethodRepository items, ILogger<PaymentMethodService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<PaymentMethodDto>>> SearchAsync(PaymentMethodQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);

        return Result<PagedResult<PaymentMethodDto>>.Success(new PagedResult<PaymentMethodDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<PaymentMethodDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var item = await _items.GetAsync(id, cancellationToken);
        return item is null
            ? Result<PaymentMethodDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PaymentMethodDto>.Success(item);
    }

    public async Task<Result<IReadOnlyList<PaymentMethodLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<PaymentMethodLookupDto>>.Success(await _items.LookupAsync(activeOnly, includeId, cancellationToken));

    public async Task<Result<PaymentMethodDto>> SaveAsync(
        int? id, SavePaymentMethodRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.PaymentMethodsManage))
        {
            return Forbidden<PaymentMethodDto>(Permissions.MasterData.PaymentMethodsManage);
        }

        int savedId;
        try
        {
            savedId = await _items.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentMethodDto>(ex);
        }

        _logger.LogInformation("Payment method {Id} saved by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<PaymentMethodDto>> SetActiveAsync(
        int id, SetReceiptMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.PaymentMethodsManage))
        {
            return Forbidden<PaymentMethodDto>(Permissions.MasterData.PaymentMethodsManage);
        }

        try
        {
            await _items.SetActiveAsync(id, request.IsActive, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PaymentMethodDto>(ex);
        }

        _logger.LogInformation("Payment method {Id} {State} by user {UserId}", id, request.IsActive ? "activated" : "deactivated", userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.PaymentMethodsManage))
        {
            return Forbidden(Permissions.MasterData.PaymentMethodsManage);
        }

        try
        {
            await _items.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Payment method {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }
}
