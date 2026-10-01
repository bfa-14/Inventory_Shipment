using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class OutOfStockAuditRepository : IOutOfStockAuditRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public OutOfStockAuditRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The DTO plus the window count the procedure adds; serialized as the DTO, so the count stays out of the JSON.</summary>
    private sealed class SearchRow : OutOfStockAuditDto
    {
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<OutOfStockAuditDto> Items, int TotalCount)> SearchAsync(
        OutOfStockAuditQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.WarehouseId,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<SearchRow>(new CommandDefinition(
            "sales.usp_OutOfStockAudit_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows, rows.Count > 0 ? rows[0].TotalCount : 0);
    }
}
