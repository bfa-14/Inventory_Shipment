using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.ReceiptRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class CashBankAccountService : ICashBankAccountService
{
    private const string NotFoundMessage = "Cash / bank account not found.";

    private readonly ICashBankAccountRepository _items;
    private readonly ILogger<CashBankAccountService> _logger;

    public CashBankAccountService(ICashBankAccountRepository items, ILogger<CashBankAccountService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<CashBankAccountDto>>> SearchAsync(CashBankAccountQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);

        return Result<PagedResult<CashBankAccountDto>>.Success(new PagedResult<CashBankAccountDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<CashBankAccountDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var item = await _items.GetAsync(id, cancellationToken);
        return item is null
            ? Result<CashBankAccountDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<CashBankAccountDto>.Success(item);
    }

    public async Task<Result<IReadOnlyList<CashBankAccountLookupDto>>> LookupAsync(
        bool activeOnly, int? currencyId, int? branchId, int? includeId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<CashBankAccountLookupDto>>.Success(
            await _items.LookupAsync(activeOnly, currencyId, branchId, includeId, cancellationToken));

    public async Task<Result<CashBankAccountDto>> SaveAsync(
        int? id, SaveCashBankAccountRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.CashBankAccountsManage))
        {
            return Forbidden<CashBankAccountDto>(Permissions.MasterData.CashBankAccountsManage);
        }

        int savedId;
        try
        {
            savedId = await _items.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<CashBankAccountDto>(ex);
        }

        _logger.LogInformation("Cash / bank account {Id} saved by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<CashBankAccountDto>> SetActiveAsync(
        int id, SetReceiptMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.CashBankAccountsManage))
        {
            return Forbidden<CashBankAccountDto>(Permissions.MasterData.CashBankAccountsManage);
        }

        try
        {
            await _items.SetActiveAsync(id, request.IsActive, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<CashBankAccountDto>(ex);
        }

        _logger.LogInformation("Cash / bank account {Id} {State} by user {UserId}", id, request.IsActive ? "activated" : "deactivated", userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.CashBankAccountsManage))
        {
            return Forbidden(Permissions.MasterData.CashBankAccountsManage);
        }

        try
        {
            await _items.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Cash / bank account {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }
}
