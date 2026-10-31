using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class BivacCostRepository : IBivacCostRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public BivacCostRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<ItemBivacPortCostDto>> GetPortCostsAsync(int itemId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ItemBivacPortCostDto>(new CommandDefinition(
            "inventory.usp_Item_BivacPortCosts_Get", new { ItemId = itemId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<IReadOnlyList<ItemBivacPortCostDto>> SetPortCostsAsync(
        int itemId, IReadOnlyList<ItemBivacPortCostRequest> costs, int userId, CancellationToken cancellationToken = default)
    {
        var table = new DataTable();
        table.Columns.Add("PortId", typeof(int));
        table.Columns.Add("CostBase", typeof(decimal));
        foreach (var cost in costs)
        {
            table.Rows.Add(cost.PortId, (object?)cost.CostBase ?? DBNull.Value);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@ItemId", itemId, DbType.Int32);
        parameters.Add("@Costs", table.AsTableValuedParameter("inventory.tvp_ItemPortCost"));
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ItemBivacPortCostDto>(new CommandDefinition(
                "inventory.usp_Item_SetBivacPortCosts", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<BivacChargeOptionsDto> GetChargeOptionsAsync(
        IReadOnlyCollection<int> containerIds, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerIds", MovementRepository.ToIdTable(containerIds).AsTableValuedParameter("logistics.tvp_IdList"));

        await using var connection = _connectionFactory.Create();
        using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_ContainerCharge_BivacOptions", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        var items = (await grid.ReadAsync<BivacChargeOptionDto>()).AsList();
        var containers = (await grid.ReadAsync<BivacContainerPortDto>()).AsList();
        return new BivacChargeOptionsDto { Items = items, Containers = containers };
    }
}
