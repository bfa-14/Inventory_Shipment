using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>The Item Balance Report's reads (script 103): the rows are worked out by the service from the ledger's events.</summary>
public interface IItemBalanceReportRepository
{
    /// <summary>reporting.usp_ItemBalance_Warehouses: the warehouses the filter offers the user.</summary>
    Task<IReadOnlyList<ItemBalanceWarehouseDto>> WarehousesAsync(int userId, CancellationToken cancellationToken = default);

    /// <summary>reporting.usp_ItemBalance_Data: the items, the warehouses, the events oldest first and the ledger's quantities.</summary>
    Task<ItemBalanceData> DataAsync(
        int userId, IReadOnlyCollection<int> warehouseIds, IReadOnlyCollection<int> itemIds, IReadOnlyCollection<int> familyIds,
        DateOnly dateFrom, DateOnly dateTo, bool detail, CancellationToken cancellationToken = default);

    /// <summary>reporting.usp_ItemBalance_Rates: the currency (null when unknown) and its rates up to Date To, oldest first.</summary>
    Task<(ItemBalanceCurrencyDto? Currency, IReadOnlyList<ItemBalanceRateRow> Rates)> RatesAsync(
        int currencyId, byte rateType, DateOnly dateTo, CancellationToken cancellationToken = default);

    /// <summary>The base currency's id (masterdata.Currencies.IsBaseCurrency).</summary>
    Task<int?> BaseCurrencyIdAsync(CancellationToken cancellationToken = default);

    Task LogRunAsync(int userId, string output, DateOnly dateFrom, DateOnly dateTo, int? currencyId, byte? rateType,
        string criteria, int rows, int durationMs, CancellationToken cancellationToken = default);
}

public sealed class ItemBalanceData
{
    public IReadOnlyList<ItemBalanceItemRow> Items { get; init; } = [];
    public IReadOnlyList<ItemBalanceWarehouseRow> Warehouses { get; init; } = [];
    public IReadOnlyList<ItemBalanceEventRow> Events { get; init; } = [];
    public IReadOnlyList<ItemBalanceLedgerRow> Ledger { get; init; } = [];
}

public sealed class ItemBalanceItemRow
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Unit { get; init; }
    public string? FamilyName { get; init; }
}

public sealed class ItemBalanceWarehouseRow
{
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public bool IsTransit { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public int RootId { get; init; }
    public string RootCode { get; init; } = string.Empty;
    public string RootName { get; init; } = string.Empty;
}

/// <summary>
/// A stock movement (Amount null) or a cost adjustment (Qty 0, Amount set). A movement in without a Cost enters at the
/// running average (a transfer's incoming leg).
/// </summary>
public sealed class ItemBalanceEventRow
{
    public int ItemId { get; init; }
    public int WarehouseId { get; init; }
    public DateTime EventDate { get; init; }
    public int Qty { get; init; }
    public decimal? Cost { get; init; }
    public decimal? Amount { get; init; }
    public string GroupCode { get; init; } = string.Empty;
    public bool InScope { get; init; }
    public bool InPeriod { get; init; }
    public DateTime? EventAt { get; init; }
    public string? DocumentTypeCode { get; init; }
    public int? DocumentId { get; init; }
    public string? DocumentNumber { get; init; }
    public int? TransferOrderId { get; init; }
}

public sealed class ItemBalanceLedgerRow
{
    public int ItemId { get; init; }
    public int WarehouseId { get; init; }
    public long QuantityBase { get; init; }
}

public sealed class ItemBalanceRateRow
{
    public DateTime RateDate { get; init; }
    public decimal Rate { get; init; }
}
