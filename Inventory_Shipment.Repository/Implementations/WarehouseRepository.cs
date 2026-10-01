using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class WarehouseRepository : IWarehouseRepository
{
    /// <summary>Columns the search procedure accepts; anything else falls back to WarehouseCode.</summary>
    private static readonly string[] SortColumns =
        ["WarehouseCode", "WarehouseName", "BranchName", "Address", "IsMainWarehouse", "IsActive", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public WarehouseRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape the search procedure returns: the joined columns plus the windowed total.</summary>
    private sealed class WarehouseRow
    {
        public int Id { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int BranchId { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public string? Address { get; init; }
        public bool IsMainWarehouse { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public int? ParentId { get; init; }
        public string? ParentCode { get; init; }
        public string? ParentName { get; init; }
        public int Level { get; init; } = 1;
        public int ChildCount { get; init; }
        public bool? AllowOutOfStockOverride { get; init; }

        public Warehouse ToWarehouse() => new()
        {
            Id = Id,
            WarehouseCode = WarehouseCode,
            WarehouseName = WarehouseName,
            BranchId = BranchId,
            BranchCode = BranchCode,
            BranchName = BranchName,
            Address = Address,
            ParentId = ParentId,
            ParentCode = ParentCode,
            ParentName = ParentName,
            Level = Level,
            ChildCount = ChildCount,
            AllowOutOfStockOverride = AllowOutOfStockOverride,
            IsMainWarehouse = IsMainWarehouse,
            IsActive = IsActive,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            UpdatedAtUtc = UpdatedAtUtc,
            UpdatedBy = UpdatedBy,
            RowVersion = RowVersion
        };
    }

    public async Task<(IReadOnlyList<Warehouse> Items, int TotalCount)> SearchAsync(
        WarehouseQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.BranchId,
            query.IsActive,
            query.IsMainWarehouse,
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = ResolveSortDirection(query.SortDir),
            PageNumber = query.Page,
            query.PageSize
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<WarehouseRow>(new CommandDefinition(
                "masterdata.usp_Warehouse_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats the same COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToWarehouse()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<Warehouse?> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<Warehouse>(new CommandDefinition(
                "masterdata.usp_Warehouse_Get", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<Warehouse?> GetMainAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<Warehouse>(new CommandDefinition(
                "masterdata.usp_Warehouse_GetMain",
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<Warehouse>> LookupAsync(
        bool activeOnly, int? branchId, int? includeId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<Warehouse>(new CommandDefinition(
                "masterdata.usp_Warehouse_Lookup",
                new { ActiveOnly = activeOnly, BranchId = branchId, IncludeId = includeId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> CreateAsync(
        Warehouse warehouse, bool replaceMainWarehouse, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@WarehouseCode", warehouse.WarehouseCode, DbType.String, size: 20);
        parameters.Add("@WarehouseName", warehouse.WarehouseName, DbType.String, size: 150);
        parameters.Add("@BranchId", warehouse.BranchId, DbType.Int32);
        parameters.Add("@Address", warehouse.Address, DbType.String, size: 500);
        parameters.Add("@IsMainWarehouse", warehouse.IsMainWarehouse, DbType.Boolean);
        parameters.Add("@IsActive", warehouse.IsActive, DbType.Boolean);
        parameters.Add("@ReplaceMainWarehouse", replaceMainWarehouse, DbType.Boolean);
        parameters.Add("@ParentId", warehouse.ParentId, DbType.Int32);
        parameters.Add("@AllowOutOfStockOverride", warehouse.AllowOutOfStockOverride, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Warehouse_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            warehouse.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateAsync(
        Warehouse warehouse, bool replaceMainWarehouse, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", warehouse.Id, DbType.Int32);
        parameters.Add("@WarehouseCode", warehouse.WarehouseCode, DbType.String, size: 20);
        parameters.Add("@WarehouseName", warehouse.WarehouseName, DbType.String, size: 150);
        parameters.Add("@BranchId", warehouse.BranchId, DbType.Int32);
        parameters.Add("@Address", warehouse.Address, DbType.String, size: 500);
        parameters.Add("@IsMainWarehouse", warehouse.IsMainWarehouse, DbType.Boolean);
        parameters.Add("@IsActive", warehouse.IsActive, DbType.Boolean);
        parameters.Add("@ReplaceMainWarehouse", replaceMainWarehouse, DbType.Boolean);
        parameters.Add("@ParentId", warehouse.ParentId, DbType.Int32);
        parameters.Add("@AllowOutOfStockOverride", warehouse.AllowOutOfStockOverride, DbType.Boolean);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Warehouse_Update", parameters,
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
                "masterdata.usp_Warehouse_SetActive", new { Id = id, IsActive = isActive, UserId = userId },
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
                "masterdata.usp_Warehouse_Delete", new { Id = id },
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
           ?? "WarehouseCode";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
}
