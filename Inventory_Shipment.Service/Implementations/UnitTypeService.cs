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

public sealed class UnitTypeService : IUnitTypeService
{
    private const string NotFoundMessage = "Unit type not found.";

    private readonly IUnitTypeRepository _unitTypes;
    private readonly ILogger<UnitTypeService> _logger;

    public UnitTypeService(IUnitTypeRepository unitTypes, ILogger<UnitTypeService> logger)
    {
        _unitTypes = unitTypes;
        _logger = logger;
    }

    public async Task<Result<PagedResult<UnitTypeDto>>> SearchAsync(
        UnitTypeQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _unitTypes.SearchAsync(query, cancellationToken);

        return Result<PagedResult<UnitTypeDto>>.Success(new PagedResult<UnitTypeDto>
        {
            Items = items.Select(u => u.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<UnitTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var unitType = await _unitTypes.GetByIdAsync(id, cancellationToken);

        return unitType is null
            ? Result<UnitTypeDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<UnitTypeDto>.Success(unitType.ToDto());
    }

    public async Task<Result<UnitTypeDto>> CreateAsync(
        SaveUnitTypeRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var unitType = ToEntity(request);

        int id;
        try
        {
            id = await _unitTypes.CreateAsync(unitType, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<UnitTypeDto>(ex);
        }

        _logger.LogInformation("Unit type {UnitTypeId} ({UnitTypeName}) created by user {UserId}",
            id, unitType.UnitTypeName, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<UnitTypeDto>> UpdateAsync(
        int id, SaveUnitTypeRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<UnitTypeDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var unitType = ToEntity(request);
        unitType.Id = id;

        try
        {
            await _unitTypes.UpdateAsync(unitType, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<UnitTypeDto>(ex);
        }

        _logger.LogInformation("Unit type {UnitTypeId} ({UnitTypeName}) updated by user {UserId}",
            id, unitType.UnitTypeName, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<UnitTypeDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _unitTypes.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<UnitTypeDto>(ex);
        }

        _logger.LogInformation("Unit type {UnitTypeId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _unitTypes.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Unit type {UnitTypeId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<UnitTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var unitTypes = await _unitTypes.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<UnitTypeLookupDto>>.Success(unitTypes.Select(u => u.ToDto()).ToList());
    }

    // ----- helpers -----

    private static UnitType ToEntity(SaveUnitTypeRequest request) => new()
    {
        UnitTypeName = request.UnitTypeName.Trim(),
        IsActive = request.IsActive
    };

    private async Task<Result<UnitTypeDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _unitTypes.GetByIdAsync(id, cancellationToken);

        return saved is null
            ? Result<UnitTypeDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<UnitTypeDto>.Success(saved.ToDto());
    }

    /// <summary>How one business rule raised by the procedures is reported to the client.</summary>
    private sealed record RuleFailure(ErrorType Type, string Message, string Code);

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.UnitTypeDuplicateName => new RuleFailure(
            ErrorType.Conflict, "A unit type with this name already exists.", "DUPLICATE_NAME"),

        SqlErrors.UnitTypeReferenced => new RuleFailure(
            ErrorType.Conflict,
            "This unit type cannot be deleted because it is used by item units. You may deactivate it instead.",
            "REFERENCED"),

        SqlErrors.UnitTypeConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),

        SqlErrors.UnitTypeNotFound => new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND"),

        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };
}
