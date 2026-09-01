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

public sealed class ItemFamilyService : IItemFamilyService
{
    private const string NotFoundMessage = "Item family not found.";

    private readonly IItemFamilyRepository _families;
    private readonly ILogger<ItemFamilyService> _logger;

    public ItemFamilyService(IItemFamilyRepository families, ILogger<ItemFamilyService> logger)
    {
        _families = families;
        _logger = logger;
    }

    public async Task<Result<IReadOnlyList<ItemFamilyDto>>> TreeAsync(CancellationToken cancellationToken = default)
    {
        var families = await _families.TreeAsync(cancellationToken);
        return Result<IReadOnlyList<ItemFamilyDto>>.Success(families.Select(f => f.ToDto()).ToList());
    }

    public async Task<Result<ItemFamilyDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var family = await _families.GetAsync(id, cancellationToken);

        return family is null
            ? Result<ItemFamilyDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ItemFamilyDto>.Success(family.ToDto());
    }

    public async Task<Result<IReadOnlyList<ItemFamilyLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var families = await _families.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<ItemFamilyLookupDto>>.Success(families.Select(f => f.ToDto()).ToList());
    }

    public async Task<Result<NextCodeDto>> NextChildCodeAsync(
        int? parentId, CancellationToken cancellationToken = default)
    {
        string suggestedCode;
        try
        {
            suggestedCode = await _families.NextChildCodeAsync(parentId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<NextCodeDto>(ex);
        }

        return Result<NextCodeDto>.Success(new NextCodeDto { SuggestedCode = suggestedCode });
    }

    public async Task<Result<ItemFamilyDto>> CreateAsync(
        SaveItemFamilyRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var family = ToEntity(request);

        int id;
        try
        {
            id = await _families.CreateAsync(family, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemFamilyDto>(ex);
        }

        _logger.LogInformation("Item family {ItemFamilyId} ({FamilyCode}) created by user {UserId}",
            id, family.FamilyCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<ItemFamilyDto>> UpdateAsync(
        int id, SaveItemFamilyRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<ItemFamilyDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var family = ToEntity(request);
        family.Id = id;

        try
        {
            await _families.UpdateAsync(family, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemFamilyDto>(ex);
        }

        _logger.LogInformation("Item family {ItemFamilyId} ({FamilyCode}) updated by user {UserId}",
            id, family.FamilyCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<ItemFamilyDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _families.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemFamilyDto>(ex);
        }

        _logger.LogInformation("Item family {ItemFamilyId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _families.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Item family {ItemFamilyId} deleted", id);
        return Result.Success();
    }

    // ----- helpers -----

    private static ItemFamily ToEntity(SaveItemFamilyRequest request) => new()
    {
        FamilyCode = request.FamilyCode.Trim(),
        FamilyName = request.FamilyName.Trim(),
        ParentId = request.ParentId,
        Description = string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim(),
        IsActive = request.IsActive
    };

    private async Task<Result<ItemFamilyDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _families.GetAsync(id, cancellationToken);

        return saved is null
            ? Result<ItemFamilyDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ItemFamilyDto>.Success(saved.ToDto());
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
        SqlErrors.ItemFamilyDuplicateCode => new RuleFailure(
            ErrorType.Conflict, "A family with this Family Code already exists.", "DUPLICATE_CODE"),

        SqlErrors.ItemFamilyDuplicateName => new RuleFailure(
            ErrorType.Conflict, "A family with this name already exists under the same parent.", "DUPLICATE_NAME"),

        SqlErrors.ItemFamilyReferenced => new RuleFailure(
            ErrorType.Conflict, exception.Message, "REFERENCED"),

        SqlErrors.ItemFamilyConcurrency => new RuleFailure(
            ErrorType.Conflict, exception.Message, "CONCURRENCY"),

        SqlErrors.ItemFamilyHasChildren => new RuleFailure(
            ErrorType.Conflict, exception.Message, "HAS_CHILDREN"),

        SqlErrors.ItemFamilyNotFound => new RuleFailure(
            ErrorType.NotFound, exception.Message, "NOT_FOUND"),

        SqlErrors.ItemFamilyCircularHierarchy => new RuleFailure(
            ErrorType.Validation, exception.Message, "CIRCULAR_HIERARCHY"),

        SqlErrors.ItemFamilyParentInactive => new RuleFailure(
            ErrorType.Validation, exception.Message, "PARENT_INACTIVE"),

        // SqlErrors.ItemFamilyValidation and anything else the procedures raise.
        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };
}
