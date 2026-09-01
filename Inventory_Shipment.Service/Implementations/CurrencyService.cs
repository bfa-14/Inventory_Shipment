using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Mapping;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class CurrencyService : ICurrencyService
{
    private const string NotFoundMessage = "Currency not found.";

    private readonly ICurrencyRepository _currencies;
    private readonly ILogger<CurrencyService> _logger;

    public CurrencyService(ICurrencyRepository currencies, ILogger<CurrencyService> logger)
    {
        _currencies = currencies;
        _logger = logger;
    }

    public async Task<Result<PagedResult<CurrencyDto>>> SearchAsync(
        CurrencyQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _currencies.SearchAsync(query, cancellationToken);

        return Result<PagedResult<CurrencyDto>>.Success(new PagedResult<CurrencyDto>
        {
            Items = items.Select(c => c.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<CurrencyDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var currency = await _currencies.GetAsync(id, cancellationToken);

        return currency is null
            ? Result<CurrencyDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<CurrencyDto>.Success(currency.ToDto());
    }

    public async Task<Result<CurrencyDto>> GetBaseAsync(CancellationToken cancellationToken = default)
    {
        var currency = await _currencies.GetBaseAsync(cancellationToken);

        return currency is null
            ? Result<CurrencyDto>.Failure(ErrorType.NotFound, "No currency is currently designated as the Base Currency.", "NOT_FOUND")
            : Result<CurrencyDto>.Success(currency.ToDto());
    }

    public async Task<Result<CurrencyDto>> CreateAsync(
        SaveCurrencyRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var currency = ToEntity(request);

        int id;
        try
        {
            id = await _currencies.CreateAsync(currency, request.ReplaceBaseCurrency, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<CurrencyDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Currency {CurrencyId} ({CurrencyCode}) created by user {UserId}",
            id, currency.CurrencyCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<CurrencyDto>> UpdateAsync(
        int id, SaveCurrencyRequest request, int userId, CancellationToken cancellationToken = default)
    {
        byte[]? rowVersion;
        try
        {
            rowVersion = string.IsNullOrWhiteSpace(request.RowVersion)
                ? null
                : Convert.FromBase64String(request.RowVersion);
        }
        catch (FormatException)
        {
            return Result<CurrencyDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var currency = ToEntity(request);
        currency.Id = id;

        try
        {
            await _currencies.UpdateAsync(currency, request.ReplaceBaseCurrency, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<CurrencyDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Currency {CurrencyId} ({CurrencyCode}) updated by user {UserId}",
            id, currency.CurrencyCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<CurrencyDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _currencies.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<CurrencyDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Currency {CurrencyId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _currencies.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync(ex, cancellationToken);
        }

        _logger.LogInformation("Currency {CurrencyId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<CurrencyLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var currencies = await _currencies.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<CurrencyLookupDto>>.Success(currencies.Select(c => c.ToDto()).ToList());
    }

    // ----- helpers -----

    private static Currency ToEntity(SaveCurrencyRequest request) => new()
    {
        // ISO 4217 codes are upper-case; the procedure normalizes too, but the log line reads better this way.
        CurrencyCode = request.CurrencyCode.Trim().ToUpperInvariant(),
        CurrencyName = request.CurrencyName.Trim(),
        Symbol = string.IsNullOrWhiteSpace(request.Symbol) ? null : request.Symbol.Trim(),
        DecimalPlaces = request.DecimalPlaces,
        IsBaseCurrency = request.IsBaseCurrency,
        IsActive = request.IsActive
    };

    private async Task<Result<CurrencyDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _currencies.GetAsync(id, cancellationToken);

        return saved is null
            ? Result<CurrencyDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<CurrencyDto>.Success(saved.ToDto());
    }

    /// <summary>How one business rule raised by the procedures is reported to the client.</summary>
    private sealed record RuleFailure(ErrorType Type, string Message, string Code, object? Data);

    private async Task<Result<T>> FailureAsync<T>(BusinessRuleException exception, CancellationToken cancellationToken)
    {
        var failure = await DescribeAsync(exception, cancellationToken);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code, failure.Data);
    }

    private async Task<Result> FailureAsync(BusinessRuleException exception, CancellationToken cancellationToken)
    {
        var failure = await DescribeAsync(exception, cancellationToken);
        return Result.Failure(failure.Type, failure.Message, failure.Code, failure.Data);
    }

    private async Task<RuleFailure> DescribeAsync(BusinessRuleException exception, CancellationToken cancellationToken)
    {
        switch (exception.Number)
        {
            case SqlErrors.CurrencyDuplicateCode:
                return new RuleFailure(
                    ErrorType.Conflict, "A currency with this Currency Code already exists.", "DUPLICATE_CODE", null);

            case SqlErrors.CurrencyBaseExists:
                // The client shows "Replace USD - US Dollar?" and retries with ReplaceBaseCurrency = true.
                return new RuleFailure(
                    ErrorType.Conflict, exception.Message, "BASE_CURRENCY_EXISTS",
                    await CurrentBaseCurrencyAsync(cancellationToken));

            case SqlErrors.CurrencyReferenced:
                return new RuleFailure(
                    ErrorType.Conflict,
                    "This currency cannot be deleted because it is referenced by other records (e.g. exchange rates). You may deactivate the currency instead.",
                    "REFERENCED", null);

            case SqlErrors.CurrencyConcurrency:
                return new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY", null);

            case SqlErrors.CurrencyBaseProtected:
                return new RuleFailure(ErrorType.Validation, exception.Message, "BASE_CURRENCY_PROTECTED", null);

            case SqlErrors.CurrencyNotFound:
                return new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND", null);

            case SqlErrors.CurrencyValidation:
            default:
                return new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION", null);
        }
    }

    private async Task<object?> CurrentBaseCurrencyAsync(CancellationToken cancellationToken)
    {
        var current = await _currencies.GetBaseAsync(cancellationToken);

        return current is null
            ? null
            : new
            {
                currentBaseCurrency = new
                {
                    id = current.Id,
                    currencyCode = current.CurrencyCode,
                    currencyName = current.CurrencyName
                }
            };
    }
}
