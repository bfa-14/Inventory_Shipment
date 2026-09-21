using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class CostingReportRepository : ICostingReportRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public CostingReportRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>
    /// The two valuation views, read directly: they are views rather than procedures because they
    /// are what a report tool would attach to, and a procedure wrapping a SELECT * would add
    /// nothing. Ordered by code so the page and an export agree without sorting either.
    /// </summary>
    public async Task<IReadOnlyList<InventoryValuationRowDto>> ValuationAsync(
        int? warehouseId, CancellationToken cancellationToken = default)
    {
        const string companyWide = """
            SELECT v.ItemId, v.ItemCode, v.ItemName,
                   WarehouseId = CAST(NULL AS INT), WarehouseCode = CAST(NULL AS NVARCHAR(20)), WarehouseName = CAST(NULL AS NVARCHAR(100)),
                   v.OnHandBase, v.AverageCost, v.InventoryValue
            FROM inventory.vw_InventoryValuation v
            ORDER BY v.ItemCode;
            """;

        const string perWarehouse = """
            SELECT v.ItemId, v.ItemCode, v.ItemName, v.WarehouseId, v.WarehouseCode, v.WarehouseName,
                   v.OnHandBase, v.AverageCost, v.InventoryValue
            FROM inventory.vw_InventoryValuationByWarehouse v
            WHERE v.WarehouseId = @WarehouseId
            ORDER BY v.ItemCode;
            """;

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<InventoryValuationRowDto>(new CommandDefinition(
            warehouseId is null ? companyWide : perWarehouse,
            new { WarehouseId = warehouseId },
            cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<IReadOnlyList<SalesProfitRowDto>> SalesProfitAsync(
        SalesProfitQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            query.BranchId,
            query.ClientId,
            query.SalesmanId,
            query.ItemFamilyId,
            query.BrandId,
            query.ItemId,
            GroupBy = SalesProfitGroupings.Normalize(query.GroupBy) ?? SalesProfitGroupings.Invoice,
        };

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<SalesProfitRowDto>(new CommandDefinition(
            "sales.usp_SalesProfit_Report", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }
}
