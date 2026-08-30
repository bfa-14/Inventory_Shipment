using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.Warehouses through its stored procedures. Every method turns a business-rule THROW
/// (52000-52007) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IWarehouseRepository
{
    /// <summary>masterdata.usp_Warehouse_Search - one page of warehouses plus the total row count.</summary>
    Task<(IReadOnlyList<Warehouse> Items, int TotalCount)> SearchAsync(
        WarehouseQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Warehouse_Get.</summary>
    Task<Warehouse?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Warehouse_GetMain - the active main warehouse, or null when there is none.</summary>
    Task<Warehouse?> GetMainAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Warehouse_Lookup - the warehouses a dropdown offers, optionally limited to one branch.
    /// <paramref name="includeId"/> keeps one extra warehouse in the list even when it is inactive.
    /// </summary>
    Task<IReadOnlyList<Warehouse>> LookupAsync(
        bool activeOnly, int? branchId, int? includeId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Warehouse_Create - returns the new id. Throws 52000-52002 / 52005 / 52007.</summary>
    Task<int> CreateAsync(Warehouse warehouse, bool replaceMainWarehouse, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Warehouse_Update - throws 52000-52002 / 52004 / 52005 / 52006 / 52007.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(Warehouse warehouse, bool replaceMainWarehouse, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Warehouse_SetActive - throws 52005 (main warehouse) / 52006 / 52007.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Warehouse_Delete - throws 52003 (referenced) / 52005 (main warehouse) / 52006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);
}
