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

public sealed class ExchangeRateService : IExchangeRateService
{
    private const string NotFoundMessage = "Exchange rate not found.";

    private readonly IExchangeRateRepository _rates;
    private readonly ICurrencyRepository _currencies;
    private readonly ILogger<ExchangeRateService> _logger;

    public ExchangeRateService(
        IExchangeRateRepository rates, ICurrencyRepository currencies, ILogger<ExchangeRateService> logger)
    {
        _rates = rates;
        _currencies = currencies;
        _logger = logger;
    }

    public async Task<Result<PagedResult<ExchangeRateDto>>> SearchAsync(
        ExchangeRateQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _rates.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ExchangeRateDto>>.Success(new PagedResult<ExchangeRateDto>
        {
            Items = items.Select(r => r.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<ExchangeRateDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var rate = await _rates.GetAsync(id, cancellationToken);

        return rate is null
            ? Result<ExchangeRateDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ExchangeRateDto>.Success(rate.ToDto());
    }

    public async Task<Result<IReadOnlyList<ExchangeRateDto>>> LatestAsync(
        int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        var rates = await _rates.GetLatestAsync(currencyId, asOfDate, cancellationToken);
        return Result<IReadOnlyList<ExchangeRateDto>>.Success(rates.Select(r => r.ToDto()).ToList());
    }

    public async Task<Result<ExchangeRateDto>> CreateAsync(
        SaveExchangeRateRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var rate = ToEntity(request);

        int id;
        try
        {
            id = await _rates.CreateAsync(rate, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<ExchangeRateDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Exchange rate {RateId} ({RateType} on {RateDate}) created by user {UserId}",
            id, rate.RateType, rate.RateDate, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<ExchangeRateDto>> UpdateAsync(
        int id, SaveExchangeRateRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<ExchangeRateDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var rate = ToEntity(request);
        rate.Id = id;

        try
        {
            await _rates.UpdateAsync(rate, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<ExchangeRateDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Exchange rate {RateId} updated by user {UserId}", id, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _rates.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync(ex, cancellationToken);
        }

        _logger.LogInformation("Exchange rate {RateId} deleted", id);
        return Result.Success();
    }

    // ----- helpers -----

    private static ExchangeRate ToEntity(SaveExchangeRateRequest request) => new()
    {
        CurrencyId = request.CurrencyId,
        RateType = request.RateType,
        RateDate = request.RateDate.ToDateTime(TimeOnly.MinValue),
        Rate = request.Rate,
        Notes = string.IsNullOrWhiteSpace(request.Notes) ? null : request.Notes.Trim()
    };

    private async Task<Result<ExchangeRateDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _rates.GetAsync(id, cancellationToken);

        return saved is null
            ? Result<ExchangeRateDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ExchangeRateDto>.Success(saved.ToDto());
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
                return new RuleFailure(
                    ErrorType.Conflict, exception.Message, "BASE_CURRENCY_EXISTS",
                    await CurrentBaseCurrencyAsync(cancellationToken));

            case SqlErrors.CurrencyReferenced:
                return new RuleFailure(
                    ErrorType.Conflict,
                    "This record cannot be deleted because it is referenced by other records.",
                    "REFERENCED", null);

            case SqlErrors.CurrencyConcurrency:
                return new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY", null);

            case SqlErrors.CurrencyBaseProtected:
                return new RuleFailure(ErrorType.Validation, exception.Message, "BASE_CURRENCY_PROTECTED", null);

            case SqlErrors.CurrencyNotFound:
                return new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND", null);

            case SqlErrors.ExchangeRateDuplicate:
                return new RuleFailure(ErrorType.Conflict, exception.Message, "DUPLICATE_RATE", null);

            case SqlErrors.CurrencyInactive:
                return new RuleFailure(ErrorType.Validation, exception.Message, "CURRENCY_INACTIVE", null);

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
