using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class BranchRepository : IBranchRepository
{
    /// <summary>Columns the search procedure accepts; anything else falls back to BranchCode.</summary>
    private static readonly string[] SortColumns =
        ["BranchCode", "BranchName", "Address", "IsMainBranch", "IsActive", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public BranchRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape the search procedure returns: every column plus the windowed total.</summary>
    private sealed class BranchRow
    {
        public int Id { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public string? Address { get; init; }
        public bool IsMainBranch { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public Branch ToBranch() => new()
        {
            Id = Id,
            BranchCode = BranchCode,
            BranchName = BranchName,
            Address = Address,
            IsMainBranch = IsMainBranch,
            IsActive = IsActive,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            UpdatedAtUtc = UpdatedAtUtc,
            UpdatedBy = UpdatedBy,
            RowVersion = RowVersion
        };
    }

    public async Task<(IReadOnlyList<Branch> Items, int TotalCount)> SearchAsync(
        BranchQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.IsActive,
            query.IsMainBranch,
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = ResolveSortDirection(query.SortDir),
            PageNumber = query.Page,
            query.PageSize
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<BranchRow>(new CommandDefinition(
                "masterdata.usp_Branch_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats the same COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToBranch()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<Branch?> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<Branch>(new CommandDefinition(
                "masterdata.usp_Branch_Get", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<Branch?> GetMainAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<Branch>(new CommandDefinition(
                "masterdata.usp_Branch_GetMain",
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> CreateAsync(
        Branch branch, bool replaceMainBranch, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@BranchCode", branch.BranchCode, DbType.String, size: 20);
        parameters.Add("@BranchName", branch.BranchName, DbType.String, size: 150);
        parameters.Add("@Address", branch.Address, DbType.String, size: 500);
        parameters.Add("@IsMainBranch", branch.IsMainBranch, DbType.Boolean);
        parameters.Add("@IsActive", branch.IsActive, DbType.Boolean);
        parameters.Add("@ReplaceMainBranch", replaceMainBranch, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Branch_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            branch.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateAsync(
        Branch branch, bool replaceMainBranch, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", branch.Id, DbType.Int32);
        parameters.Add("@BranchCode", branch.BranchCode, DbType.String, size: 20);
        parameters.Add("@BranchName", branch.BranchName, DbType.String, size: 150);
        parameters.Add("@Address", branch.Address, DbType.String, size: 500);
        parameters.Add("@IsMainBranch", branch.IsMainBranch, DbType.Boolean);
        parameters.Add("@IsActive", branch.IsActive, DbType.Boolean);
        parameters.Add("@ReplaceMainBranch", replaceMainBranch, DbType.Boolean);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Branch_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetActiveAsync(
        int id, bool isActive, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Branch_SetActive", new { Id = id, IsActive = isActive, UserId = userId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Branch_Delete", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- helpers -----

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "BranchCode";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
}
