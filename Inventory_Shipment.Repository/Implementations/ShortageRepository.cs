using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ShortageRepository : IShortageRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public ShortageRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<ShortageRowDto>> ReportAsync(ShortageQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            query.BranchId,
            query.WarehouseId,
            query.ItemFamilyId,
            query.BrandId,
            query.SupplierId,
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.OnlyShortages,
            DaysForAverage = query.DaysForAverage <= 0 ? 30 : query.DaysForAverage,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ShortageRowDto>(new CommandDefinition(
                "inventory.usp_Shortage_Report", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }
}
