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

    /// <summary>(81) One row per container of a leg made "one per container": its truck no. (or vessel) and ETA.</summary>
    private const string LegContainerTypeName = "logistics.tvp_LegContainer";

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
        var history = (await multi.ReadAsync<MovementAuditDto>()).AsList();       // (82) its splits

        return header with { Containers = containers, Charges = charges, Attachments = attachments, History = history };
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

    /// <summary>
    /// (82) The procedure answers one row only when its Cancel undid a split (read before its commit, like the split's own
    /// answer); every other call answers none, read as null. All or nothing in the procedure, so a deadlock victim is run
    /// again whole.
    /// </summary>
    public async Task<MovementSplitUndoneDto?> SetStatusAsync(
        int id, string action, DateOnly? date, string? reason, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new { Id = id, Action = action, Date = ToDate(date), Reason = reason, RowVersion = rowVersion, UserId = userId };
        try
        {
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                var rows = await connection.QueryAsync<MovementSplitUndoneDto>(new CommandDefinition(
                    "logistics.usp_Movement_SetStatus", parameters, commandTimeout: _connectionFactory.BatchCommandTimeout,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
                return rows.FirstOrDefault();
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// NO DEADLOCK RETRY HERE: the procedure gives each container its own transaction and catches its errors, so a
    /// deadlock comes back as that container's 'Error' row - and running the whole list again would report the drafts the
    /// first run made as "already has a draft" instead of "created".
    /// </summary>
    public async Task<IReadOnlyList<MovementReceiptResultDto>> CreateGoodsReceiptsAsync(
        int id, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var connection = _connectionFactory.Create();
            return (await connection.QueryAsync<MovementReceiptResultDto>(new CommandDefinition(
                "purchase.usp_GoodsReceipt_CreateForMovement", new { MovementId = id, UserId = userId },
                commandTimeout: _connectionFactory.BatchCommandTimeout,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

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
                    commandTimeout: _connectionFactory.BatchCommandTimeout,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// (81) logistics.usp_Container_NextStepPreview: three result sets in one round trip - one row per container asked
    /// for, the groups, the ones that cannot move on by reason. Set-based in the procedure; the batch timeout for the
    /// thousands of containers a selection can hold.
    /// </summary>
    public async Task<NextStepPreviewDto> NextStepPreviewAsync(
        IEnumerable<int> containerIds, bool canConfirm, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerIds", ToIdTable(containerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@CanConfirm", canConfirm, DbType.Boolean);

        try
        {
            await using var connection = _connectionFactory.Create();
            using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                "logistics.usp_Container_NextStepPreview", parameters,
                commandTimeout: _connectionFactory.BatchCommandTimeout,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            // An unknown id has no step: the procedure's functions see "no movement" and would say Ship.
            var containers = (await multi.ReadAsync<ContainerNextStepDto>())
                .Select(c => c.Found ? c : c with { Kind = null })
                .ToList();
            var groups = (await multi.ReadAsync<NextStepGroupDto>()).AsList();
            var blocked = (await multi.ReadAsync<NextStepBlockedDto>()).AsList();
            return new NextStepPreviewDto { Containers = containers, Groups = groups, Blocked = blocked };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// (81) logistics.usp_Movement_AddLeg: a new leg for a group, one movement or one per container, all or nothing; the
    /// movements made. confirmDrafts is the one the service allows (containers.confirm), not the request's.
    /// </summary>
    public async Task<IReadOnlyList<AddedLegDto>> AddLegAsync(
        AddLegCommand command, bool confirmDrafts, int userId, CancellationToken cancellationToken = default)
    {
        // logistics.tvp_LegContainer (ContainerId, VehicleOrVessel, Eta): the truck no. and ETA of each container
        var perContainer = new DataTable();
        perContainer.Columns.Add("ContainerId", typeof(int));
        perContainer.Columns.Add("VehicleOrVessel", typeof(string));
        perContainer.Columns.Add("Eta", typeof(DateTime));
        foreach (var leg in command.PerContainer.GroupBy(p => p.ContainerId).Select(g => g.Last()))
        {
            perContainer.Rows.Add(
                leg.ContainerId,
                string.IsNullOrWhiteSpace(leg.VehicleOrVessel) ? DBNull.Value : leg.VehicleOrVessel.Trim(),
                (object?)ToDate(leg.Eta) ?? DBNull.Value);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@ContainerIds", ToIdTable(command.ContainerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@MovementTypeId", command.MovementTypeId, DbType.Int32);
        parameters.Add("@FromPlaceId", command.FromPlaceId, DbType.Int32);
        parameters.Add("@ToPlaceId", command.ToPlaceId, DbType.Int32);
        parameters.Add("@StartDate", ToDate(command.StartDate), DbType.Date);
        parameters.Add("@Eta", ToDate(command.Eta), DbType.Date);
        parameters.Add("@CarrierPartyId", command.CarrierPartyId, DbType.Int32);
        parameters.Add("@VehicleOrVessel", command.VehicleOrVessel, DbType.String, size: 100);
        parameters.Add("@VoyageNo", command.VoyageNo, DbType.String, size: 30);
        parameters.Add("@Reference", command.Reference, DbType.String, size: 50);
        parameters.Add("@BlNo", command.BlNo, DbType.String, size: 30);
        parameters.Add("@BlDate", ToDate(command.BlDate), DbType.Date);
        parameters.Add("@Notes", command.Notes, DbType.String, size: 1000);
        parameters.Add("@StartNow", command.StartNow, DbType.Boolean);
        parameters.Add("@ConfirmDrafts", confirmDrafts, DbType.Boolean);
        parameters.Add("@UpdateContainers", command.UpdateContainers, DbType.Boolean);
        parameters.Add("@OnePerContainer", command.OnePerContainer, DbType.Boolean);
        parameters.Add("@PerContainer", perContainer.AsTableValuedParameter(LegContainerTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);

        try
        {
            // All or nothing in the procedure, so a deadlock victim is simply run again.
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                return (IReadOnlyList<AddedLegDto>)(await connection.QueryAsync<AddedLegDto>(new CommandDefinition(
                    "logistics.usp_Movement_AddLeg", parameters,
                    commandTimeout: _connectionFactory.BatchCommandTimeout,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// (82) logistics.usp_Movement_SplitContainers: the ticked containers of a movement in progress get their own movement,
    /// all or nothing in the procedure (one transaction under the movement's lock), so a deadlock victim is simply run
    /// again. completeDate is the completion that follows, checked by the procedure before anything is split.
    /// </summary>
    public async Task<MovementSplitDto> SplitContainersAsync(
        int movementId, IReadOnlyList<int> containerIds, byte[]? rowVersion, DateOnly? completeDate, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@MovementId", movementId, DbType.Int32);
        parameters.Add("@ContainerIds", ToIdTable(containerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@CompleteDate", ToDate(completeDate), DbType.Date);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                return await connection.QuerySingleAsync<MovementSplitDto>(new CommandDefinition(
                    "logistics.usp_Movement_SplitContainers", parameters,
                    commandTimeout: _connectionFactory.BatchCommandTimeout,
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

    public async Task<IReadOnlyList<MovementJoinCandidateDto>> JoinCandidatesAsync(int containerId, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var connection = _connectionFactory.Create();
            return (await connection.QueryAsync<MovementJoinCandidateDto>(new CommandDefinition(
                "logistics.usp_Movement_JoinCandidates", new { ContainerId = containerId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
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
    /// the same moment is enough for one side to be killed. A movement may carry any number of containers
    /// (script 78): save, start and complete get the batch timeout.
    /// </summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandTimeout: _connectionFactory.BatchCommandTimeout,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
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
