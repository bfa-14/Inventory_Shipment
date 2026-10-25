using System.Data;
using System.Globalization;
using Dapper;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>(92) Dapper over the security procedures of script 92 (4.3.5). Business errors are wrapped as UserRepository does.</summary>
public sealed class UserWarehouseRepository : IUserWarehouseRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public UserWarehouseRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<(bool IsUnrestricted, string? Message, IReadOnlyList<(int WarehouseId, string Message)> PerWarehouse)> RefusalAsync(
        int userId, IEnumerable<int> warehouseIds, CancellationToken cancellationToken = default)
    {
        var ids = warehouseIds.Distinct().ToList();

        await using var connection = _connectionFactory.Create();
        try
        {
            using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "security.usp_User_WarehouseRefusal",
                new { UserId = userId, WarehouseIds = Join(ids) },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var answer = await grid.ReadSingleOrDefaultAsync<RefusalRow>();
            // RS2 only matters for a restricted user asked about warehouses; read it only when the procedure sent it.
            var perWarehouse = !grid.IsConsumed
                ? (await grid.ReadAsync<PerWarehouseRow>()).Select(r => (r.WarehouseId, r.Message ?? string.Empty)).ToList()
                : [];

            // No row cannot happen (RS1 is always one row); read as "may" rather than refusing on nothing.
            return answer is null
                ? (true, null, [])
                : (answer.IsUnrestricted, string.IsNullOrWhiteSpace(answer.Message) ? null : answer.Message, perWarehouse);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<UserWarehousesDto> GetAsync(int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "security.usp_User_Warehouses_Get", new { UserId = userId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var header = await grid.ReadSingleAsync<HeaderRow>();
            var ticked = (await grid.ReadAsync<TickedRow>()).AsList();
            var usableCount = await grid.ReadSingleOrDefaultAsync<int?>() ?? 0;
            var history = (await grid.ReadAsync<HistoryRow>()).AsList();

            return new UserWarehousesDto
            {
                UserId = header.UserId,
                Username = header.Username,
                FullName = header.FullName,
                AllWarehouses = header.AllWarehouses,
                IsSystemAdministrator = header.IsSystemAdministrator,
                UsableCount = usableCount,
                Warehouses = ticked.Select(t => new UserWarehouseDto
                {
                    Id = t.WarehouseId,
                    Code = t.WarehouseCode,
                    Name = t.WarehouseName,
                    BranchId = t.BranchId,
                    BranchCode = t.BranchCode ?? string.Empty,
                    BranchName = t.BranchName ?? string.Empty,
                    IsActive = t.IsActive,
                    HasChildren = t.ChildCount > 0,
                    GrantedAtUtc = t.GrantedAtUtc,
                    GrantedByName = t.GrantedByName ?? "-",
                }).ToList(),
                History = history.Select(h => new UserWarehouseChangeDto
                {
                    Id = h.Id,
                    Before = h.BeforeText,
                    After = h.AfterText,
                    ChangedAtUtc = h.ChangedAtUtc,
                    ChangedByName = h.ChangedByName,
                }).ToList(),
            };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetAsync(int userId, bool allWarehouses, IReadOnlyCollection<int> warehouseIds, int? changedBy,
        CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "security.usp_User_SetWarehouses",
                new
                {
                    UserId = userId,
                    AllWarehouses = allWarehouses,
                    // With All warehouses the ticks are cleared whatever is sent: nothing to send.
                    WarehouseIds = allWarehouses ? null : Join(warehouseIds) ?? string.Empty,
                    ChangedBy = changedBy,
                },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<UserWarehouseSummaries> SummariesAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "security.usp_User_WarehouseSummaries",
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var ticks = (await grid.ReadAsync<UserWarehouseTick>()).AsList();
            var users = (await grid.ReadAsync<UserWarehouseFlags>()).AsList();
            return new UserWarehouseSummaries { Ticks = ticks, Users = users };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>Comma-separated, as the procedures read them with STRING_SPLIT (usp_User_SetRoles does the same); null for none.</summary>
    private static string? Join(IEnumerable<int> ids)
    {
        var text = string.Join(",", ids.Select(id => id.ToString(CultureInfo.InvariantCulture)));
        return text.Length == 0 ? null : text;
    }

    private sealed class RefusalRow
    {
        public bool IsUnrestricted { get; init; }
        public string? Message { get; init; }
    }

    private sealed class PerWarehouseRow
    {
        public int WarehouseId { get; init; }
        public string? Message { get; init; }
    }

    private sealed class HeaderRow
    {
        public int UserId { get; init; }
        public string Username { get; init; } = string.Empty;
        public string FullName { get; init; } = string.Empty;
        public bool AllWarehouses { get; init; }
        public bool IsSystemAdministrator { get; init; }
    }

    private sealed class TickedRow
    {
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int BranchId { get; init; }
        public string? BranchCode { get; init; }
        public string? BranchName { get; init; }
        public bool IsActive { get; init; }
        public int ChildCount { get; init; }
        public DateTime GrantedAtUtc { get; init; }
        public string? GrantedByName { get; init; }
    }

    private sealed class HistoryRow
    {
        public long Id { get; init; }
        public string BeforeText { get; init; } = string.Empty;
        public string AfterText { get; init; } = string.Empty;
        public DateTime ChangedAtUtc { get; init; }
        public string? ChangedByName { get; init; }
    }
}
