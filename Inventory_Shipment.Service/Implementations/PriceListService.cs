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

public sealed class PriceListService : IPriceListService
{
    private const string NotFoundMessage = "Price list not found.";

    private readonly IPriceListRepository _priceLists;
    private readonly ILogger<PriceListService> _logger;

    public PriceListService(IPriceListRepository priceLists, ILogger<PriceListService> logger)
    {
        _priceLists = priceLists;
        _logger = logger;
    }

    public async Task<Result<PagedResult<PriceListDto>>> SearchAsync(
        PriceListQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _priceLists.SearchAsync(query, cancellationToken);

        return Result<PagedResult<PriceListDto>>.Success(new PagedResult<PriceListDto>
        {
            Items = items.Select(p => p.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<PriceListDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var priceList = await _priceLists.GetByIdAsync(id, cancellationToken);

        return priceList is null
            ? Result<PriceListDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PriceListDto>.Success(priceList.ToDto());
    }

    public async Task<Result<PriceListDto>> CreateAsync(
        SavePriceListRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var priceList = ToEntity(request);

        int id;
        try
        {
            id = await _priceLists.CreateAsync(priceList, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PriceListDto>(ex);
        }

        _logger.LogInformation("Price list {PriceListId} ({PriceListCode}) created by user {UserId}",
            id, priceList.PriceListCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<PriceListDto>> UpdateAsync(
        int id, SavePriceListRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<PriceListDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var priceList = ToEntity(request);
        priceList.Id = id;

        try
        {
            await _priceLists.UpdateAsync(priceList, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PriceListDto>(ex);
        }

        _logger.LogInformation("Price list {PriceListId} ({PriceListCode}) updated by user {UserId}",
            id, priceList.PriceListCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<PriceListDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _priceLists.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PriceListDto>(ex);
        }

        _logger.LogInformation("Price list {PriceListId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _priceLists.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Price list {PriceListId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<PriceListLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var priceLists = await _priceLists.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<PriceListLookupDto>>.Success(priceLists.Select(p => p.ToDto()).ToList());
    }

    // ----- helpers -----

    private static PriceList ToEntity(SavePriceListRequest request) => new()
    {
        PriceListCode = request.PriceListCode.Trim(),
        PriceListName = request.PriceListName.Trim(),
        CurrencyId = request.CurrencyId,
        Description = string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim(),
        IsActive = request.IsActive
    };

    private async Task<Result<PriceListDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _priceLists.GetByIdAsync(id, cancellationToken);

        return saved is null
            ? Result<PriceListDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PriceListDto>.Success(saved.ToDto());
    }

    /// <summary>How one business rule raised by the procedures is reported to the client.</summary>
    private sealed record RuleFailure(ErrorType Type, string Message, string Code);

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    public async Task<Result<UnitPriceResolutionDto>> ResolveUnitPriceAsync(
        int itemUnitId, int priceListId, int? branchId, CancellationToken cancellationToken = default)
    {
        var found = await _priceLists.ResolveUnitPriceAsync(itemUnitId, priceListId, branchId, cancellationToken);

        // No row is "no price", carried as a null Price rather than a NotFound: the page treats it as
        // a state of the line, not as a broken request.
        return Result<UnitPriceResolutionDto>.Success(
            found ?? new UnitPriceResolutionDto { ItemUnitId = itemUnitId, PriceListId = priceListId });
    }

    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        // 58001 covers a duplicate code and a duplicate name; the procedure message says which one.
        SqlErrors.PriceListDuplicateCode => new RuleFailure(
            ErrorType.Conflict, exception.Message, "DUPLICATE_CODE"),

        SqlErrors.PriceListReferenced => new RuleFailure(
            ErrorType.Conflict,
            "This price list cannot be deleted because it contains prices or is referenced by other records. You may deactivate it instead.",
            "REFERENCED"),

        SqlErrors.PriceListConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),

        SqlErrors.PriceListNotFound => new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND"),

        SqlErrors.PriceListCurrencyInactive => new RuleFailure(
            ErrorType.Validation, exception.Message, "CURRENCY_INACTIVE"),

        SqlErrors.PriceListCurrencyLocked => new RuleFailure(
            ErrorType.Validation, exception.Message, "CURRENCY_LOCKED"),

        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };
}
