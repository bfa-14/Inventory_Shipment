using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IWarehouseService
{
    Task<Result<PagedResult<WarehouseDto>>> SearchAsync(WarehouseQuery query, CancellationToken cancellationToken = default);

    Task<Result<WarehouseDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The active main warehouse, or NotFound when no warehouse carries the flag.</summary>
    Task<Result<WarehouseDto>> GetMainAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Warehouses for a dropdown; <paramref name="includeId"/> keeps one inactive warehouse visible. (90) The "On the
    /// way" warehouses of transfer orders only with <paramref name="includeTransit"/> (or as the includeId).
    /// </summary>
    /// <remarks>(92) <paramref name="userId"/>: the reader, for each row's CanUse.</remarks>
    Task<Result<IReadOnlyList<WarehouseLookupDto>>> LookupAsync(
        bool activeOnly, int? branchId, int? includeId, bool includeTransit = false, int? userId = null,
        CancellationToken cancellationToken = default);

    Task<Result<WarehouseDto>> CreateAsync(SaveWarehouseRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<WarehouseDto>> UpdateAsync(int id, SaveWarehouseRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<WarehouseDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    /// <remarks>(92) <paramref name="userId"/>: who deletes it (the ticks go with the warehouse, each user's history says so).</remarks>
    Task<Result> DeleteAsync(int id, int? userId = null, CancellationToken cancellationToken = default);
}
