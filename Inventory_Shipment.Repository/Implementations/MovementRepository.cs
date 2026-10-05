using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class MovementRepository : IMovementRepository
{
    /// <summary>Matched by TYPE NAME on the server; a wrong one fails with a message that never mentions the type.</summary>
    private const string IdListTypeName = "logistics.tvp_IdList";

    private const string TextListTypeName = "logistics.tvp_TextList";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the start date.</summary>
    private static readonly string[] SortColumns = ["MovementNo", "StartDate", "Eta", "EndDate", "Status", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public MovementRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The list row plus the window count the procedure adds. Serialized as the base type, so the count stays out of the JSON.</summary>
    private sealed record ListRow : MovementListDto
    {
        public int TotalCount { get; init; }
    }

    /// <summary>A candidate plus the window count, which stays out of the JSON the same way.</summary>
    private sealed record CandidateRow : MovementContainerCandidateDto
    {
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<MovementListDto> Items, int TotalCount)> SearchAsync(
        MovementQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            Status = MovementStatus.ToCode(query.Status),
            query.MovementTypeId,
            query.PlaceId,
            query.ContainerId,
            query.CarrierPartyId,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "StartDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<ListRow>(new CommandDefinition(
            "logistics.usp_Movement_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows, rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    public async Task<MovementDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_Movement_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<MovementDto>();
        if (header is null)
        {
            return null;
        }

        var containers = (await multi.ReadAsync<MovementContainerDto>()).AsList();
        var charges = (await multi.ReadAsync<MovementChargeDto>()).AsList();
        var attachments = (await multi.ReadAsync<MovementAttachmentDto>()).AsList();

        return header with { Containers = containers, Charges = charges, Attachments = attachments };
    }

    public async Task<int> SaveAsync(
        SaveMovementRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@MovementTypeId", request.MovementTypeId, DbType.Int32);
        parameters.Add("@FromPlaceId", request.FromPlaceId, DbType.Int32);
        parameters.Add("@ToPlaceId", request.ToPlaceId, DbType.Int32);
        parameters.Add("@PlannedDate", ToDate(request.PlannedDate), DbType.Date);
        parameters.Add("@StartDate", ToDate(request.StartDate), DbType.Date);
        parameters.Add("@Eta", ToDate(request.Eta), DbType.Date);
        parameters.Add("@CarrierPartyId", request.CarrierPartyId, DbType.Int32);
        parameters.Add("@VehicleOrVessel", request.VehicleOrVessel, DbType.String, size: 100);
        parameters.Add("@VoyageNo", request.VoyageNo, DbType.String, size: 30);
        parameters.Add("@Reference", request.Reference, DbType.String, size: 50);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@ContainerIds", ToIdTable(request.ContainerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("logistics.usp_Movement_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task SetStatusAsync(
        int id, string action, DateOnly? date, string? reason, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Movement_SetStatus",
            new { Id = id, Action = action, Date = ToDate(date), Reason = reason, RowVersion = rowVersion, UserId = userId },
            cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Movement_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public async Task<ShippedMovementDto> ShipContainersAsync(
        ShipContainersRequest request, bool confirmDrafts, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerIds", ToIdTable(request.ContainerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@MovementTypeId", request.MovementTypeId, DbType.Int32);
        parameters.Add("@FromPlaceId", request.FromPlaceId, DbType.Int32);
        parameters.Add("@ToPlaceId", request.ToPlaceId, DbType.Int32);
        parameters.Add("@StartDate", ToDate(request.StartDate), DbType.Date);
        parameters.Add("@Eta", ToDate(request.Eta), DbType.Date);
        parameters.Add("@CarrierPartyId", request.CarrierPartyId, DbType.Int32);
        parameters.Add("@VehicleOrVessel", request.VehicleOrVessel, DbType.String, size: 100);
        parameters.Add("@VoyageNo", request.VoyageNo, DbType.String, size: 30);
        parameters.Add("@Reference", request.Reference, DbType.String, size: 50);
        parameters.Add("@BlNo", request.BlNo, DbType.String, size: 30);
        parameters.Add("@BlDate", ToDate(request.BlDate), DbType.Date);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@StartNow", request.StartNow, DbType.Boolean);
        parameters.Add("@ConfirmDrafts", confirmDrafts, DbType.Boolean);
        parameters.Add("@UpdateContainers", request.UpdateContainers, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            // All or nothing in the procedure, so a deadlock victim is simply run again.
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                return await connection.QuerySingleAsync<ShippedMovementDto>(new CommandDefinition(
                    "logistics.usp_Movement_ShipContainers", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<(IReadOnlyList<MovementContainerCandidateDto> Items, int TotalCount)> ContainerCandidatesAsync(
        MovementContainerCandidateQuery query, int page, int pageSize, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            query.MovementId,
            query.FromPlaceId,
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.PurchaseOrderId,
            query.SupplierId,
            Status = ContainerStatus.ToCode(query.Status),
            query.IncludeBlocked,
            PageNumber = page,
            PageSize = pageSize,
            query.ToPlaceId,
            query.MovementTypeId,
        };

        try
        {
            await using var connection = _connectionFactory.Create();
            var rows = (await connection.QueryAsync<CandidateRow>(new CommandDefinition(
                "logistics.usp_Movement_ContainerCandidates", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

            return (rows, rows.Count > 0 ? rows[0].TotalCount : 0);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<MovementContainerMatchDto>> MatchContainersAsync(
        int? movementId, int fromPlaceId, IReadOnlyList<string?> numbers, int? toPlaceId = null, int? movementTypeId = null,
        CancellationToken cancellationToken = default)
    {
        // logistics.tvp_TextList (RowNo, Value): the position keeps the order of the file.
        var table = new DataTable();
        table.Columns.Add("RowNo", typeof(int));
        table.Columns.Add("Value", typeof(string));
        for (var i = 0; i < numbers.Count; i++)
        {
            table.Rows.Add(i + 1, (object?)numbers[i]?.Trim() ?? DBNull.Value);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@MovementId", movementId, DbType.Int32);
        parameters.Add("@FromPlaceId", fromPlaceId, DbType.Int32);
        parameters.Add("@Numbers", table.AsTableValuedParameter(TextListTypeName));
        parameters.Add("@ToPlaceId", toPlaceId, DbType.Int32);
        parameters.Add("@MovementTypeId", movementTypeId, DbType.Int32);

        try
        {
            await using var connection = _connectionFactory.Create();
            return (await connection.QueryAsync<MovementContainerMatchDto>(new CommandDefinition(
                "logistics.usp_Movement_MatchContainers", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim: starting or completing
    /// a movement refreshes every container it carries, and a container page reading one of them at
    /// the same moment is enough for one side to be killed.
    /// </summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure,
                    cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>logistics.tvp_IdList (Id). Duplicates dropped: the column is the primary key.</summary>
    internal static DataTable ToIdTable(IEnumerable<int> ids)
    {
        var table = new DataTable();
        table.Columns.Add("Id", typeof(int));
        foreach (var id in ids.Distinct())
        {
            table.Rows.Add(id);
        }

        return table;
    }

    private static DateTime? ToDate(DateOnly? value) => value?.ToDateTime(TimeOnly.MinValue);

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
