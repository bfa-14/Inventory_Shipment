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

public sealed class BranchService : IBranchService
{
    private const string NotFoundMessage = "Branch not found.";

    private readonly IBranchRepository _branches;
    private readonly ILogger<BranchService> _logger;

    public BranchService(IBranchRepository branches, ILogger<BranchService> logger)
    {
        _branches = branches;
        _logger = logger;
    }

    public async Task<Result<PagedResult<BranchDto>>> SearchAsync(
        BranchQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _branches.SearchAsync(query, cancellationToken);

        return Result<PagedResult<BranchDto>>.Success(new PagedResult<BranchDto>
        {
            Items = items.Select(b => b.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<BranchDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var branch = await _branches.GetByIdAsync(id, cancellationToken);

        return branch is null
            ? Result<BranchDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<BranchDto>.Success(branch.ToDto());
    }

    public async Task<Result<BranchDto>> GetMainAsync(CancellationToken cancellationToken = default)
    {
        var branch = await _branches.GetMainAsync(cancellationToken);

        return branch is null
            ? Result<BranchDto>.Failure(ErrorType.NotFound, "No branch is currently designated as the Main Branch.", "NOT_FOUND")
            : Result<BranchDto>.Success(branch.ToDto());
    }

    public async Task<Result<BranchDto>> CreateAsync(
        SaveBranchRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var branch = ToEntity(request);

        int id;
        try
        {
            id = await _branches.CreateAsync(branch, request.ReplaceMainBranch, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<BranchDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Branch {BranchId} ({BranchCode}) created by user {UserId}",
            id, branch.BranchCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<BranchDto>> UpdateAsync(
        int id, SaveBranchRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<BranchDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var branch = ToEntity(request);
        branch.Id = id;

        try
        {
            await _branches.UpdateAsync(branch, request.ReplaceMainBranch, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<BranchDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Branch {BranchId} ({BranchCode}) updated by user {UserId}",
            id, branch.BranchCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<BranchDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _branches.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<BranchDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Branch {BranchId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _branches.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync(ex, cancellationToken);
        }

        _logger.LogInformation("Branch {BranchId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<BranchLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var branches = await _branches.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<BranchLookupDto>>.Success(branches.Select(b => b.ToDto()).ToList());
    }

    // ----- helpers -----

    private static Branch ToEntity(SaveBranchRequest request) => new()
    {
        BranchCode = request.BranchCode.Trim(),
        BranchName = request.BranchName.Trim(),
        Address = string.IsNullOrWhiteSpace(request.Address) ? null : request.Address.Trim(),
        IsMainBranch = request.IsMainBranch,
        IsActive = request.IsActive
    };

    private async Task<Result<BranchDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _branches.GetByIdAsync(id, cancellationToken);

        return saved is null
            ? Result<BranchDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<BranchDto>.Success(saved.ToDto());
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
            case SqlErrors.BranchDuplicateCode:
                return new RuleFailure(
                    ErrorType.Conflict, "A branch with this Branch Code already exists.", "DUPLICATE_CODE", null);

            case SqlErrors.BranchMainExists:
                // The client shows "Replace BR-001 Head Office?" and retries with ReplaceMainBranch = true.
                return new RuleFailure(
                    ErrorType.Conflict, exception.Message, "MAIN_BRANCH_EXISTS",
                    await CurrentMainBranchAsync(cancellationToken));

            case SqlErrors.BranchReferenced:
                return new RuleFailure(
                    ErrorType.Conflict,
                    "This branch cannot be deleted because it is referenced by other records. You may deactivate the branch instead.",
                    "REFERENCED", null);

            case SqlErrors.Concurrency:
                return new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY", null);

            case SqlErrors.BranchMainProtected:
                return new RuleFailure(ErrorType.Validation, exception.Message, "MAIN_BRANCH_PROTECTED", null);

            case SqlErrors.BranchNotFound:
                return new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND", null);

            case SqlErrors.Validation:
            default:
                return new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION", null);
        }
    }

    private async Task<object?> CurrentMainBranchAsync(CancellationToken cancellationToken)
    {
        var main = await _branches.GetMainAsync(cancellationToken);
        return main is null ? null : new { currentMainBranch = main.ToDto() };
    }
}
