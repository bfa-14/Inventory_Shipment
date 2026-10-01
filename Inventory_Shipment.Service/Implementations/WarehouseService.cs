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

public sealed class WarehouseService : IWarehouseService
{
    private const string NotFoundMessage = "Warehouse not found.";

    private readonly IWarehouseRepository _warehouses;
    private readonly ILogger<WarehouseService> _logger;

    public WarehouseService(IWarehouseRepository warehouses, ILogger<WarehouseService> logger)
    {
        _warehouses = warehouses;
        _logger = logger;
    }

    public async Task<Result<PagedResult<WarehouseDto>>> SearchAsync(
        WarehouseQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _warehouses.SearchAsync(query, cancellationToken);

        return Result<PagedResult<WarehouseDto>>.Success(new PagedResult<WarehouseDto>
        {
            Items = items.Select(w => w.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<WarehouseDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var warehouse = await _warehouses.GetByIdAsync(id, cancellationToken);

        return warehouse is null
            ? Result<WarehouseDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<WarehouseDto>.Success(warehouse.ToDto());
    }

    public async Task<Result<WarehouseDto>> GetMainAsync(CancellationToken cancellationToken = default)
    {
        var warehouse = await _warehouses.GetMainAsync(cancellationToken);

        return warehouse is null
            ? Result<WarehouseDto>.Failure(
                ErrorType.NotFound, "No warehouse is currently designated as the Main Warehouse.", "NOT_FOUND")
            : Result<WarehouseDto>.Success(warehouse.ToDto());
    }

    public async Task<Result<IReadOnlyList<WarehouseLookupDto>>> LookupAsync(
        bool activeOnly, int? branchId, int? includeId, CancellationToken cancellationToken = default)
    {
        var warehouses = await _warehouses.LookupAsync(activeOnly, branchId, includeId, cancellationToken);
        return Result<IReadOnlyList<WarehouseLookupDto>>.Success(warehouses.Select(w => w.ToLookupDto()).ToList());
    }

    public async Task<Result<WarehouseDto>> CreateAsync(
        SaveWarehouseRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var warehouse = ToEntity(request);

        int id;
        try
        {
            id = await _warehouses.CreateAsync(warehouse, request.ReplaceMainWarehouse, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<WarehouseDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Warehouse {WarehouseId} ({WarehouseCode}) created by user {UserId}",
            id, warehouse.WarehouseCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<WarehouseDto>> UpdateAsync(
        int id, SaveWarehouseRequest request, int userId, CancellationToken cancellationToken = default)
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
            return Result<WarehouseDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var warehouse = ToEntity(request);
        warehouse.Id = id;

        try
        {
            await _warehouses.UpdateAsync(warehouse, request.ReplaceMainWarehouse, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<WarehouseDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Warehouse {WarehouseId} ({WarehouseCode}) updated by user {UserId}",
            id, warehouse.WarehouseCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<WarehouseDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _warehouses.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync<WarehouseDto>(ex, cancellationToken);
        }

        _logger.LogInformation("Warehouse {WarehouseId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _warehouses.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return await FailureAsync(ex, cancellationToken);
        }

        _logger.LogInformation("Warehouse {WarehouseId} deleted", id);
        return Result.Success();
    }

    // ----- helpers -----

    private static Warehouse ToEntity(SaveWarehouseRequest request) => new()
    {
        WarehouseCode = request.WarehouseCode.Trim(),
        WarehouseName = request.WarehouseName.Trim(),
        BranchId = request.BranchId,
        Address = string.IsNullOrWhiteSpace(request.Address) ? null : request.Address.Trim(),
        ParentId = request.ParentId,
        IsMainWarehouse = request.IsMainWarehouse,
        IsActive = request.IsActive,
        AllowOutOfStockOverride = request.AllowOutOfStockOverride
    };

    private async Task<Result<WarehouseDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _warehouses.GetByIdAsync(id, cancellationToken);

        return saved is null
            ? Result<WarehouseDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<WarehouseDto>.Success(saved.ToDto());
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
            case SqlErrors.WarehouseDuplicateCode:
                return new RuleFailure(
                    ErrorType.Conflict, "A warehouse with this Warehouse Code already exists.", "DUPLICATE_CODE", null);

            case SqlErrors.WarehouseMainExists:
                // The client shows "Replace WH-001 Main Warehouse?" and retries with ReplaceMainWarehouse = true.
                return new RuleFailure(
                    ErrorType.Conflict, exception.Message, "MAIN_WAREHOUSE_EXISTS",
                    await CurrentMainWarehouseAsync(cancellationToken));

            case SqlErrors.WarehouseReferenced:
                return new RuleFailure(
                    ErrorType.Conflict,
                    "This warehouse cannot be deleted because it contains inventory or is referenced by other records. You may deactivate the warehouse instead.",
                    "REFERENCED", null);

            case SqlErrors.WarehouseConcurrency:
                return new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY", null);

            case SqlErrors.WarehouseMainProtected:
                return new RuleFailure(ErrorType.Validation, exception.Message, "MAIN_WAREHOUSE_PROTECTED", null);

            case SqlErrors.WarehouseNotFound:
                return new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND", null);

            case SqlErrors.WarehouseBranchInactive:
                return new RuleFailure(ErrorType.Validation, exception.Message, "BRANCH_INACTIVE", null);

            // A move that would have put the warehouse under itself. The procedure's message names
            // the parent that was picked, which is the thing the reader has to change.
            case SqlErrors.WarehouseCircular:
                return new RuleFailure(ErrorType.Validation, exception.Message, "CIRCULAR_HIERARCHY", null);

            case SqlErrors.WarehouseValidation:
            default:
                return new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION", null);
        }
    }

    private async Task<object?> CurrentMainWarehouseAsync(CancellationToken cancellationToken)
    {
        var main = await _warehouses.GetMainAsync(cancellationToken);
        return main is null ? null : new { currentMainWarehouse = main.ToDto() };
    }
}
