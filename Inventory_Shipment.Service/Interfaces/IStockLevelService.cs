using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Stock levels per warehouse (script 91): Inventory › Stock Levels, the "Stock levels per warehouse" card of Item
/// Definition, their history and the export. inventory.stocklevels.view reads, inventory.stocklevels.edit changes; the
/// refusals are the procedures' sentences (56000 → 400 VALIDATION, 56004 → 409 CONCURRENCY, 56006 → 404 NOT_FOUND).
/// </summary>
public interface IStockLevelService
{
    Task<Result<StockLevelListResult>> SearchAsync(
        StockLevelQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The company view: Item Definition's Minimum / Maximum Quantity against the stock (the Dashboard's figure).</summary>
    Task<Result<CompanyStockLevelListResult>> CompanySearchAsync(
        CompanyStockLevelQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>One item's levels, all or nothing; answers the item's rows again and the sentence to show.</summary>
    Task<Result<SetStockLevelsResult>> SetAsync(
        int itemId, SetStockLevelsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> RemoveAsync(
        int itemId, int warehouseId, string? rowVersion, string? source, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<StockLevelHistoryDto>>> HistoryAsync(
        int itemId, int warehouseId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Stock_Levels.xlsx of the same query as the list: the import's five columns first (the round trip).</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        StockLevelQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
