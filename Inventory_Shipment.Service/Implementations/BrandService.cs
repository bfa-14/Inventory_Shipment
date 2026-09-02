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

public sealed class BrandService : IBrandService
{
    private const string NotFoundMessage = "Brand not found.";

    private readonly IBrandRepository _brands;
    private readonly ILogger<BrandService> _logger;

    public BrandService(IBrandRepository brands, ILogger<BrandService> logger)
    {
        _brands = brands;
        _logger = logger;
    }

    public async Task<Result<PagedResult<BrandDto>>> SearchAsync(
        BrandQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _brands.SearchAsync(query, cancellationToken);

        return Result<PagedResult<BrandDto>>.Success(new PagedResult<BrandDto>
        {
            Items = items.Select(b => b.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<BrandDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var brand = await _brands.GetByIdAsync(id, cancellationToken);

        return brand is null
            ? Result<BrandDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<BrandDto>.Success(brand.ToDto());
    }

    public async Task<Result<BrandDto>> CreateAsync(
        SaveBrandRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var brand = ToEntity(request);

        int id;
        try
        {
            id = await _brands.CreateAsync(brand, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<BrandDto>(ex);
        }

        _logger.LogInformation("Brand {BrandId} ({BrandCode}) created by user {UserId}",
            id, brand.BrandCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<BrandDto>> UpdateAsync(
        int id, SaveBrandRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<BrandDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var brand = ToEntity(request);
        brand.Id = id;

        try
        {
            await _brands.UpdateAsync(brand, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<BrandDto>(ex);
        }

        _logger.LogInformation("Brand {BrandId} ({BrandCode}) updated by user {UserId}",
            id, brand.BrandCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<BrandDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _brands.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<BrandDto>(ex);
        }

        _logger.LogInformation("Brand {BrandId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _brands.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Brand {BrandId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<BrandLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var brands = await _brands.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<BrandLookupDto>>.Success(brands.Select(b => b.ToDto()).ToList());
    }

    // ----- helpers -----

    private static Brand ToEntity(SaveBrandRequest request) => new()
    {
        BrandCode = request.BrandCode.Trim(),
        BrandName = request.BrandName.Trim(),
        Description = string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim(),
        IsActive = request.IsActive
    };

    private async Task<Result<BrandDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _brands.GetByIdAsync(id, cancellationToken);

        return saved is null
            ? Result<BrandDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<BrandDto>.Success(saved.ToDto());
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
        SqlErrors.BrandDuplicateCode => new RuleFailure(
            ErrorType.Conflict, "A brand with this Brand Code already exists.", "DUPLICATE_CODE"),

        SqlErrors.BrandReferenced => new RuleFailure(
            ErrorType.Conflict,
            "This brand cannot be deleted because it is assigned to existing items or other records. You may deactivate the brand instead.",
            "REFERENCED"),

        SqlErrors.BrandConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),

        SqlErrors.BrandNotFound => new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND"),

        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };
}
