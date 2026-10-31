using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ContainerReportRepository : IContainerReportRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public ContainerReportRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>
    /// The procedure's three result sets in one round trip: the rows, each row's share of the posted charges per type
    /// (folded into <see cref="ContainerReportRowDto.Charges"/> here), and the charge types.
    /// </summary>
    public async Task<(IReadOnlyList<ContainerReportRowDto> Rows, IReadOnlyList<ContainerReportChargeTypeDto> ChargeTypes)> ReportAsync(
        ContainerReportQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("Search", string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(), DbType.String);
        parameters.Add("SupplierId", query.SupplierId, DbType.Int32);
        parameters.Add("ItemId", query.ItemId, DbType.Int32);
        parameters.Add("ItemFamilyId", query.ItemFamilyId, DbType.Int32);
        parameters.Add("BranchId", query.BranchId, DbType.Int32);
        // DbType.Date, not DateTime: the procedure's parameters are DATE.
        parameters.Add("OrderDateFrom", query.OrderDateFrom?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("OrderDateTo", query.OrderDateTo?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("OffloadedFrom", query.OffloadedFrom?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("OffloadedTo", query.OffloadedTo?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("IncludePending", query.IncludePending, DbType.Boolean);
        parameters.Add("IncludeReceived", query.IncludeReceived, DbType.Boolean);

        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_ContainerReport", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var rows = (await grid.ReadAsync<ContainerReportRowDto>()).AsList();
        var shares = await grid.ReadAsync<ChargeShare>();
        var chargeTypes = (await grid.ReadAsync<ContainerReportChargeTypeDto>()).AsList();

        var byRow = rows.ToDictionary(r => r.RowKey);
        foreach (var share in shares)
        {
            if (!byRow.TryGetValue(share.RowKey, out var row)) continue;
            row.Charges ??= [];
            row.Charges[share.ChargeTypeId] = share.AmountBase;
        }

        return (rows, chargeTypes);
    }

    private sealed class ChargeShare
    {
        public string RowKey { get; init; } = string.Empty;
        public int ChargeTypeId { get; init; }
        public decimal AmountBase { get; init; }
    }
}
