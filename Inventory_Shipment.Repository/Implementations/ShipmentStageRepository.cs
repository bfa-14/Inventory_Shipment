using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ShipmentStageRepository : IShipmentStageRepository
{
    private const string IdListTypeName = "logistics.tvp_IdList";

    private const string TextListTypeName = "logistics.tvp_TextList";

    private readonly ISqlConnectionFactory _connectionFactory;

    public ShipmentStageRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<ShipmentStageDto>> ListAsync(bool activeOnly, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return (await connection.QueryAsync<ShipmentStageDto>(new CommandDefinition(
            "logistics.usp_ShipmentStage_List", new { ActiveOnly = activeOnly },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
    }

    public async Task<int> SaveAsync(int? id, SaveShipmentStageRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@StageName", request.StageName, DbType.String, size: 100);
        parameters.Add("@Kind", request.Kind, DbType.Byte);
        parameters.Add("@MovementTypeId", request.MovementTypeId, DbType.Int32);
        parameters.Add("@FromPlaceId", request.FromPlaceId, DbType.Int32);
        parameters.Add("@ToPlaceId", request.ToPlaceId, DbType.Int32);
        parameters.Add("@SortOrder", request.SortOrder, DbType.Int32);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("logistics.usp_ShipmentStage_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_ShipmentStage_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public async Task<ShipmentStageCheckDto> CheckAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_ShipmentStage_Check", commandTimeout: _connectionFactory.BatchCommandTimeout,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        var stages = (await grid.ReadAsync<ShipmentStageCountDto>()).AsList();
        var misfits = (await grid.ReadAsync<ShipmentStageMisfitDto>()).AsList();
        return new ShipmentStageCheckDto { Stages = stages, NotOnAStage = misfits };
    }

    public async Task<IReadOnlyList<ShipmentStagePreviewRowDto>> PreviewAsync(
        int stageId, IReadOnlyCollection<int> containerIds, bool canConfirm, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@StageId", stageId, DbType.Int32);
        parameters.Add("@ContainerIds", ToIdTable(containerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@CanConfirm", canConfirm, DbType.Boolean);

        try
        {
            await using var connection = _connectionFactory.Create();
            return (await connection.QueryAsync<ShipmentStagePreviewRowDto>(new CommandDefinition(
                "logistics.usp_ShipmentStage_Preview", parameters, commandTimeout: _connectionFactory.BatchCommandTimeout,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<ShipmentStageMatchRowDto>> MatchNumbersAsync(
        IReadOnlyList<string?> numbers, CancellationToken cancellationToken = default)
    {
        // logistics.tvp_TextList (RowNo, Value): the position keeps the order of the file.
        var table = new DataTable();
        table.Columns.Add("RowNo", typeof(int));
        table.Columns.Add("Value", typeof(string));
        for (var i = 0; i < numbers.Count; i++)
        {
            table.Rows.Add(i + 1, (object?)numbers[i]?.Trim() ?? DBNull.Value);
        }

        await using var connection = _connectionFactory.Create();
        return (await connection.QueryAsync<ShipmentStageMatchRowDto>(new CommandDefinition(
            "logistics.usp_ShipmentStage_MatchNumbers",
            new { Numbers = table.AsTableValuedParameter(TextListTypeName) },
            commandTimeout: _connectionFactory.BatchCommandTimeout,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
    }

    public async Task<IReadOnlyDictionary<int, int>> DraftReceiptsAsync(
        IReadOnlyCollection<int> containerIds, CancellationToken cancellationToken = default)
    {
        if (containerIds.Count == 0) return new Dictionary<int, int>();
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<(int ContainerId, int GoodsReceiptId)>(new CommandDefinition(
            """
            SELECT g.ContainerId, GoodsReceiptId = MAX(g.Id)
            FROM purchase.GoodsReceipts g
            INNER JOIN @Ids x ON x.Id = g.ContainerId
            WHERE g.Status = 1
            GROUP BY g.ContainerId
            """,
            new { Ids = ToIdTable(containerIds).AsTableValuedParameter(IdListTypeName) },
            cancellationToken: cancellationToken));
        return rows.ToDictionary(r => r.ContainerId, r => r.GoodsReceiptId);
    }

    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private static DataTable ToIdTable(IEnumerable<int> ids)
    {
        var table = new DataTable();
        table.Columns.Add("Id", typeof(int));
        foreach (var id in ids.Distinct())
        {
            table.Rows.Add(id);
        }

        return table;
    }

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }
}
