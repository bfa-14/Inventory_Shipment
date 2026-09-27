using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class MovementTypeService : IMovementTypeService
{
    private const string NotFoundMessage = "Movement type not found.";

    private readonly IMovementTypeRepository _items;
    private readonly ILogger<MovementTypeService> _logger;

    public MovementTypeService(IMovementTypeRepository items, ILogger<MovementTypeService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<MovementTypeDto>>> SearchAsync(MovementTypeQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);

        return Result<PagedResult<MovementTypeDto>>.Success(new PagedResult<MovementTypeDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<MovementTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var item = await _items.GetAsync(id, cancellationToken);
        return item is null
            ? Result<MovementTypeDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<MovementTypeDto>.Success(item);
    }

    public async Task<Result<IReadOnlyList<MovementTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<MovementTypeLookupDto>>.Success(await _items.LookupAsync(activeOnly, includeId, cancellationToken));

    public async Task<Result<MovementTypeDto>> SaveAsync(
        int? id, SaveMovementTypeRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.MovementTypesManage))
        {
            return Forbidden<MovementTypeDto>(Permissions.MasterData.MovementTypesManage);
        }

        int savedId;
        try
        {
            savedId = await _items.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<MovementTypeDto>(ex);
        }

        _logger.LogInformation("Movement type {Id} saved by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<MovementTypeDto>> SetActiveAsync(
        int id, SetLogisticsMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.MovementTypesManage))
        {
            return Forbidden<MovementTypeDto>(Permissions.MasterData.MovementTypesManage);
        }

        try
        {
            await _items.SetActiveAsync(id, request.IsActive, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<MovementTypeDto>(ex);
        }

        _logger.LogInformation("Movement type {Id} {State} by user {UserId}", id, request.IsActive ? "activated" : "deactivated", userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.MovementTypesManage))
        {
            return Forbidden<MovementTypeDto>(Permissions.MasterData.MovementTypesManage);
        }

        try
        {
            await _items.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Movement type {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }
}
