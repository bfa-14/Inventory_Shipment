using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Stock levels per warehouse over the procedures of script 91 (inventory.usp_StockLevel_* and
/// inventory.usp_ItemWarehouseLevel_*). Business refusals arrive as <see cref="Exceptions.BusinessRuleException"/> with
/// the procedure's number (56000 validation, 56004 changed or removed by another user, 56006 not found) and sentence.
/// </summary>
public interface IStockLevelRepository
{
    /// <summary>Each item in each warehouse of the scope with its level and where it stands; the scope's totals.</summary>
    Task<(IReadOnlyList<StockLevelRowDto> Rows, StockLevelTotalsDto Totals)> SearchAsync(
        StockLevelQuery query, CancellationToken cancellationToken = default);

    /// <summary>Item Definition's company Minimum / Maximum Quantity against the branch's or the company's stock.</summary>
    Task<CompanyStockLevelListResult> CompanySearchAsync(
        CompanyStockLevelQuery query, CancellationToken cancellationToken = default);

    /// <summary>One item's levels in one or more warehouses, all or nothing, audited with <paramref name="source"/>.</summary>
    Task SetAsync(
        int itemId, IReadOnlyList<ItemWarehouseLevelInput> levels, string? source, int userId,
        CancellationToken cancellationToken = default);

    Task RemoveAsync(
        int itemId, int warehouseId, byte[]? rowVersion, string? source, int userId, CancellationToken cancellationToken = default);

    /// <summary>Newest first.</summary>
    Task<IReadOnlyList<StockLevelHistoryDto>> HistoryAsync(
        int itemId, int warehouseId, CancellationToken cancellationToken = default);

    /// <summary>Every row judged (inventory.fn_ItemWarehouseLevel_ImportJudge); nothing written.</summary>
    Task<IReadOnlyList<StockLevelImportRow>> ImportCheckAsync(
        IReadOnlyList<StockLevelFileRow> rows, int userId, CancellationToken cancellationToken = default);

    /// <summary>The Valid and Warning rows written in ONE transaction, judged again; the outcome of every row and the counts.</summary>
    Task<StockLevelImportResult> ImportAsync(
        IReadOnlyList<StockLevelFileRow> rows, string? fileName, int userId, CancellationToken cancellationToken = default);
}

/// <summary>One row of inventory.tvp_ItemWarehouseLevel: a warehouse's Min / Max and the level's row version when it was read.</summary>
public sealed record ItemWarehouseLevelInput(int WarehouseId, int? MinQuantityBase, int? MaxQuantityBase, byte[]? RowVersion);
