using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ContainerChargeReportRepository : IContainerChargeReportRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public ContainerChargeReportRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<ContainerChargeReportData> DataAsync(
        IReadOnlyCollection<int> chargeTypeIds, string dateBasis, DateOnly? dateFrom, DateOnly? dateTo, string? search,
        int? supplierId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("ChargeTypeIds", string.Join(',', chargeTypeIds), DbType.String);
        parameters.Add("DateBasis", dateBasis, DbType.String);
        // DbType.Date, not DateTime: the procedure's parameters are DATE.
        parameters.Add("DateFrom", dateFrom?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("DateTo", dateTo?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("Search", search, DbType.String);
        parameters.Add("SupplierId", supplierId, DbType.Int32);

        // Every container of the period with its journey: the long timeout of the batch calls.
        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "reporting.usp_ContainerChargeReport", parameters,
            commandType: CommandType.StoredProcedure, commandTimeout: _connectionFactory.BatchCommandTimeout,
            cancellationToken: cancellationToken));

        return new ContainerChargeReportData
        {
            Containers = (await grid.ReadAsync<ContainerChargeContainerRow>()).AsList(),
            Charges = (await grid.ReadAsync<ContainerChargeRow>()).AsList(),
            ChargeTypes = (await grid.ReadAsync<ContainerChargeTypeDto>()).AsList(),
        };
    }

    public async Task<ContainerChargeReportOptions> OptionsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT Id, ChargeCode, ChargeName, IsDeduction, IsActive FROM purchase.ChargeTypes ORDER BY IsActive DESC, ChargeName;
            SELECT p.Id, p.PartyCode, p.PartyName
            FROM masterdata.Parties p
            WHERE EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                          WHERE d.SupplierId = p.Id)
            ORDER BY p.PartyName;
            """,
            cancellationToken: cancellationToken));

        return new ContainerChargeReportOptions
        {
            ChargeTypes = (await grid.ReadAsync<ContainerChargeTypeDto>()).AsList(),
            Suppliers = (await grid.ReadAsync<ContainerChargeSupplierDto>()).AsList(),
        };
    }

    public async Task<string?> BaseCurrencyCodeAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QueryFirstOrDefaultAsync<string?>(new CommandDefinition(
            "SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 ORDER BY Id",
            cancellationToken: cancellationToken));
    }
}
