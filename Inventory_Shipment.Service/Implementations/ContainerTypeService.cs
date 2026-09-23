using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ContainerTypeService : IContainerTypeService
{
    private const string NotFoundMessage = "Container type not found.";

    /// <summary>69013 on a master data row is its code (or category + sub type), not a container number.</summary>
    private const string DuplicateCode = "DUPLICATE_CODE";

    private readonly IContainerTypeRepository _items;
    private readonly ILogger<ContainerTypeService> _logger;

    public ContainerTypeService(IContainerTypeRepository items, ILogger<ContainerTypeService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<ContainerTypeDto>>> SearchAsync(ContainerTypeQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ContainerTypeDto>>.Success(new PagedResult<ContainerTypeDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<ContainerTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var item = await _items.GetAsync(id, cancellationToken);
        return item is null
            ? Result<ContainerTypeDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ContainerTypeDto>.Success(item);
    }

    public async Task<Result<IReadOnlyList<ContainerTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<ContainerTypeLookupDto>>.Success(await _items.LookupAsync(activeOnly, includeId, cancellationToken));

    public async Task<Result<ContainerTypeDto>> SaveAsync(
        int? id, SaveContainerTypeRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.ContainerTypesManage))
        {
            return Forbidden<ContainerTypeDto>(Permissions.MasterData.ContainerTypesManage);
        }

        int savedId;
        try
        {
            savedId = await _items.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainerTypeDto>(ex, DuplicateCode);
        }

        _logger.LogInformation("Container type {Id} saved by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<ContainerTypeDto>> SetActiveAsync(
        int id, SetLogisticsMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.ContainerTypesManage))
        {
            return Forbidden<ContainerTypeDto>(Permissions.MasterData.ContainerTypesManage);
        }

        try
        {
            await _items.SetActiveAsync(id, request.IsActive, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainerTypeDto>(ex, DuplicateCode);
        }

        _logger.LogInformation("Container type {Id} {State} by user {UserId}", id, request.IsActive ? "activated" : "deactivated", userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.ContainerTypesManage))
        {
            return Forbidden<ContainerTypeDto>(Permissions.MasterData.ContainerTypesManage);
        }

        try
        {
            await _items.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex, DuplicateCode);
        }

        _logger.LogInformation("Container type {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }
}
