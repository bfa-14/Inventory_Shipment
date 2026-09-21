using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ChargeTypeService : IChargeTypeService
{
    private const string NotFoundMessage = "Charge type not found.";

    private readonly IChargeTypeRepository _chargeTypes;
    private readonly ILogger<ChargeTypeService> _logger;

    public ChargeTypeService(IChargeTypeRepository chargeTypes, ILogger<ChargeTypeService> logger)
    {
        _chargeTypes = chargeTypes;
        _logger = logger;
    }

    public async Task<Result<PagedResult<ChargeTypeDto>>> SearchAsync(
        ChargeTypeQuery query, CancellationToken cancellationToken = default)
    {
        if (query.AllocationMethod is not null && ChargeAllocationMethods.Normalize(query.AllocationMethod) is null)
        {
            return Result<PagedResult<ChargeTypeDto>>.Failure(
                ErrorType.Validation, "Allocation method must be Value, Quantity, Weight, Volume or Manual.", "VALIDATION");
        }

        var (items, totalCount) = await _chargeTypes.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ChargeTypeDto>>.Success(new PagedResult<ChargeTypeDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<IReadOnlyList<ChargeTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<ChargeTypeLookupDto>>.Success(
            await _chargeTypes.LookupAsync(activeOnly, includeId, cancellationToken));

    public async Task<Result<ChargeTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var type = await _chargeTypes.GetAsync(id, cancellationToken);
        return type is null
            ? Result<ChargeTypeDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ChargeTypeDto>.Success(type);
    }

    public async Task<Result<ChargeTypeDto>> SaveAsync(
        int? id, SaveChargeTypeRequest request, int userId, CancellationToken cancellationToken = default)
    {
        int savedId;
        try
        {
            savedId = await _chargeTypes.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ChargeTypeDto>(ex);
        }

        _logger.LogInformation("Charge type {ChargeTypeId} saved by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<ChargeTypeDto>> SetActiveAsync(
        int id, SetChargeTypeActiveRequest request, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _chargeTypes.SetActiveAsync(id, request.IsActive, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ChargeTypeDto>(ex);
        }

        _logger.LogInformation(
            "Charge type {ChargeTypeId} {State} by user {UserId}", id, request.IsActive ? "activated" : "deactivated", userId);

        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _chargeTypes.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Charge type {ChargeTypeId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedure's THROWs, classified. THE MESSAGE IS ALWAYS THE PROCEDURE'S. A duplicate is a
    /// 409 rather than a 400: the request is well formed, it is the world that disagrees with it,
    /// and the page puts the message on the field that clashed.
    /// </summary>
    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.ChargeTypeValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.ChargeTypeDuplicateCode => new RuleFailure(ErrorType.Conflict, exception.Message, "DUPLICATE_CODE"),
        SqlErrors.ChargeTypeDuplicateName => new RuleFailure(ErrorType.Conflict, exception.Message, "DUPLICATE_NAME"),
        SqlErrors.ChargeTypeConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.ChargeTypeInUse => new RuleFailure(ErrorType.Conflict, exception.Message, "IN_USE"),
        SqlErrors.ChargeTypeNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
    };

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }

    private readonly record struct RuleFailure(ErrorType Type, string Message, string Code);
}
