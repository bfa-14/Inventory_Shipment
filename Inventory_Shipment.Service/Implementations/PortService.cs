using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class PortService : IPortService
{
    private const string NotFoundMessage = "Port not found.";

    /// <summary>69013 on a master data row is its code (or category + sub type), not a container number.</summary>
    private const string DuplicateCode = "DUPLICATE_CODE";

    private readonly IPortRepository _items;
    private readonly ILogger<PortService> _logger;

    public PortService(IPortRepository items, ILogger<PortService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<PortDto>>> SearchAsync(PortQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);

        return Result<PagedResult<PortDto>>.Success(new PagedResult<PortDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<PortDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var item = await _items.GetAsync(id, cancellationToken);
        return item is null
            ? Result<PortDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PortDto>.Success(item);
    }

    public async Task<Result<IReadOnlyList<PortLookupDto>>> LookupAsync(
        string? kind, bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<PortLookupDto>>.Success(await _items.LookupAsync(kind, activeOnly, includeId, cancellationToken));

    public async Task<Result<PortDto>> SaveAsync(
        int? id, SavePortRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.PortsManage))
        {
            return Forbidden<PortDto>(Permissions.MasterData.PortsManage);
        }

        int savedId;
        try
        {
            savedId = await _items.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PortDto>(ex, DuplicateCode);
        }

        _logger.LogInformation("Port {Id} saved by user {UserId}", savedId, userId);
        return await GetAsync(savedId, cancellationToken);
    }

    public async Task<Result<PortDto>> SetActiveAsync(
        int id, SetLogisticsMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.PortsManage))
        {
            return Forbidden<PortDto>(Permissions.MasterData.PortsManage);
        }

        try
        {
            await _items.SetActiveAsync(id, request.IsActive, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PortDto>(ex, DuplicateCode);
        }

        _logger.LogInformation("Port {Id} {State} by user {UserId}", id, request.IsActive ? "activated" : "deactivated", userId);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.PortsManage))
        {
            return Forbidden<PortDto>(Permissions.MasterData.PortsManage);
        }

        try
        {
            await _items.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex, DuplicateCode);
        }

        _logger.LogInformation("Port {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }
}
