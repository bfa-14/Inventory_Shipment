using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>
/// Stock levels per warehouse over script 91's procedures. Nothing is decided here: the formula (Projected, the status)
/// is inventory.fn_StockPosition's, every refusal the procedures' (a leaf, never On the way, an active warehouse, Max not
/// below Min, the row versions), the import's whole judgement inventory.fn_ItemWarehouseLevel_ImportJudge's - read by its
/// check AND its import, so what the preview said is what the import does. This class shapes the table types and reads
/// the result sets.
///
/// EVERY WRITE IS ONE TRANSACTION in its procedure, so a deadlock victim is run again (<see cref="SqlRetry"/>); the import
/// of a file (up to 20,000 rows, one transaction) gets the batch command timeout.
/// </summary>
public sealed class StockLevelRepository : IStockLevelRepository
{
    /* Matched by TYPE NAME on the server. FROZEN in script 91 (3.3.2): a later change takes a new type. */
    private const string LevelTypeName = "inventory.tvp_ItemWarehouseLevel";
    private const string ImportTypeName = "inventory.tvp_ItemWarehouseLevelImport";

    /* The table types' column sizes: a longer text could never match a code or a name anyway. */
    private const int ItemRefLength = 100;
    private const int WarehouseRefLength = 150;
    private const int ParseErrorLength = 300;
    private const int FileNameLength = 260;
    private const int SourceLength = 20;

    private readonly ISqlConnectionFactory _connectionFactory;

    public StockLevelRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>Result set 1 of usp_StockLevel_Search, flat; the row version as the server sends it.</summary>
    private sealed class LevelRow
    {
        public int ItemId { get; init; }
        public string? ItemCode { get; init; }
        public string? ItemName { get; init; }
        public bool ItemIsActive { get; init; }
        public string? ItemFamilyName { get; init; }
        public string? BrandName { get; init; }
        public int WarehouseId { get; init; }
        public string? WarehouseCode { get; init; }
        public string? WarehouseName { get; init; }
        public bool WarehouseIsActive { get; init; }
        public int BranchId { get; init; }
        public string? BranchCode { get; init; }
        public string? BranchName { get; init; }
        public bool HasLevel { get; init; }
        public int? MinQuantityBase { get; init; }
        public int? MaxQuantityBase { get; init; }
        public int OnHandBase { get; init; }
        public int InOnTheWayBase { get; init; }
        public int InToDispatchBase { get; init; }
        public int OutToDispatchBase { get; init; }
        public int ProjectedBase { get; init; }
        public int ToReachMaxBase { get; init; }
        public string? Status { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public string? UpdatedByName { get; init; }
        public byte[]? RowVersion { get; init; }
    }

    public async Task<(IReadOnlyList<StockLevelRowDto> Rows, StockLevelTotalsDto Totals)> SearchAsync(
        StockLevelQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Search", Trimmed(query.Search), DbType.String, size: 100);
        parameters.Add("@BranchId", query.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", query.WarehouseId, DbType.Int32);
        parameters.Add("@ItemFamilyId", query.ItemFamilyId, DbType.Int32);
        parameters.Add("@BrandId", query.BrandId, DbType.Int32);
        parameters.Add("@ItemId", query.ItemId, DbType.Int32);
        // Blank is NULL: every level. An unknown status is the procedure's own refusal (56000), in its words.
        parameters.Add("@Status", Trimmed(query.Status), DbType.String, size: 20);
        parameters.Add("@ActiveItemsOnly", query.ActiveItemsOnly, DbType.Boolean);
        parameters.Add("@IncludeInactiveWarehouses", query.IncludeInactiveWarehouses, DbType.Boolean);

        return await QueryMultipleAsync("inventory.usp_StockLevel_Search", parameters, null, async multi =>
        {
            var rows = (await multi.ReadAsync<LevelRow>()).Select(ToDto).ToList();
            var totals = await multi.ReadSingleOrDefaultAsync<StockLevelTotalsDto>() ?? new StockLevelTotalsDto();
            return ((IReadOnlyList<StockLevelRowDto>)rows, totals);
        }, cancellationToken);
    }

    private sealed class CompanyRow
    {
        public int ItemId { get; init; }
        public string? ItemCode { get; init; }
        public string? ItemName { get; init; }
        public bool ItemIsActive { get; init; }
        public string? ItemFamilyName { get; init; }
        public string? BrandName { get; init; }
        public int OnHandBase { get; init; }
        public int MinQuantity { get; init; }
        public int? MaxQuantity { get; init; }
        public string? Status { get; init; }
        public int MissingBase { get; init; }
        public int WarehouseLevelCount { get; init; }
    }

    public async Task<CompanyStockLevelListResult> CompanySearchAsync(
        CompanyStockLevelQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Search", Trimmed(query.Search), DbType.String, size: 100);
        parameters.Add("@BranchId", query.BranchId, DbType.Int32);
        parameters.Add("@ItemFamilyId", query.ItemFamilyId, DbType.Int32);
        parameters.Add("@BrandId", query.BrandId, DbType.Int32);
        parameters.Add("@Status", Trimmed(query.Status), DbType.String, size: 20);
        parameters.Add("@ActiveItemsOnly", query.ActiveItemsOnly, DbType.Boolean);

        return await QueryMultipleAsync("inventory.usp_StockLevel_CompanySearch", parameters, null, async multi =>
        {
            var rows = (await multi.ReadAsync<CompanyRow>()).Select(r => new CompanyStockLevelRowDto
            {
                ItemId = r.ItemId,
                ItemCode = r.ItemCode ?? string.Empty,
                ItemName = r.ItemName ?? string.Empty,
                ItemIsActive = r.ItemIsActive,
                ItemFamilyName = r.ItemFamilyName,
                BrandName = r.BrandName,
                OnHandBase = r.OnHandBase,
                MinQuantity = r.MinQuantity,
                MaxQuantity = r.MaxQuantity,
                MissingBase = r.MissingBase,
                Status = r.Status ?? StockLevelStatuses.Ok,
                WarehouseLevelCount = r.WarehouseLevelCount,
            }).ToList();
            var totals = await multi.ReadSingleOrDefaultAsync<CompanyStockLevelTotalsDto>() ?? new CompanyStockLevelTotalsDto();
            // Result 3: the scope - a branch, or NULL for the company (a row either way; none read as the company).
            var scope = await multi.ReadSingleOrDefaultAsync<CompanyStockLevelScopeDto>() ?? new CompanyStockLevelScopeDto();
            return new CompanyStockLevelListResult { Rows = rows, Totals = totals, Scope = scope };
        }, cancellationToken);
    }

    public async Task<IReadOnlyList<StockLevelHistoryDto>> HistoryAsync(
        int itemId, int warehouseId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<StockLevelHistoryDto>(new CommandDefinition(
                "inventory.usp_ItemWarehouseLevel_History", new { ItemId = itemId, WarehouseId = warehouseId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public Task SetAsync(
        int itemId, IReadOnlyList<ItemWarehouseLevelInput> levels, string? source, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ItemId", itemId, DbType.Int32);
        parameters.Add("@Levels", ToLevelTable(levels).AsTableValuedParameter(LevelTypeName));
        parameters.Add("@Source", Cut(Trimmed(source), SourceLength) ?? StockLevelSources.ItemCard, DbType.String, size: SourceLength);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("inventory.usp_ItemWarehouseLevel_Set", parameters, cancellationToken);
    }

    public Task RemoveAsync(
        int itemId, int warehouseId, byte[]? rowVersion, string? source, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ItemId", itemId, DbType.Int32);
        parameters.Add("@WarehouseId", warehouseId, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@Source", Cut(Trimmed(source), SourceLength) ?? StockLevelSources.ItemCard, DbType.String, size: SourceLength);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("inventory.usp_ItemWarehouseLevel_Remove", parameters, cancellationToken);
    }

    /* ── the import ───────────────────────────────────────────────────────────────────────────── */

    /// <summary>One row of fn_ItemWarehouseLevel_ImportJudge, as its columns are named.</summary>
    private sealed class JudgedRow
    {
        public int RowNumber { get; init; }
        public string? Status { get; init; }
        public string? Action { get; init; }
        public string? Message { get; init; }
        public string? ItemInput { get; init; }
        public int? ItemId { get; init; }
        public string? ItemCode { get; init; }
        public string? ItemName { get; init; }
        public bool? ItemIsActive { get; init; }
        public string? WarehouseInput { get; init; }
        public int? WarehouseId { get; init; }
        public string? WarehouseCode { get; init; }
        public string? WarehouseName { get; init; }
        public string? BranchCode { get; init; }
        public int? MinQuantityBase { get; init; }
        public int? MaxQuantityBase { get; init; }
        public bool IsRemove { get; init; }
        public bool HasLevel { get; init; }
        public int? CurrentMinBase { get; init; }
        public int? CurrentMaxBase { get; init; }
    }

    public async Task<IReadOnlyList<StockLevelImportRow>> ImportCheckAsync(
        IReadOnlyList<StockLevelFileRow> rows, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Rows", ToImportTable(rows).AsTableValuedParameter(ImportTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            var judged = await connection.QueryAsync<JudgedRow>(new CommandDefinition(
                "inventory.usp_ItemWarehouseLevel_ImportCheck", parameters,
                commandTimeout: _connectionFactory.BatchCommandTimeout,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return judged.Select(j => new StockLevelImportRow
            {
                RowNumber = j.RowNumber,
                Status = j.Status ?? StockLevelImportStatus.Error,
                Action = j.Action ?? StockLevelImportActions.None,
                Message = j.Message,
                ItemInput = j.ItemInput,
                ItemId = j.ItemId,
                ItemCode = j.ItemCode,
                ItemName = j.ItemName,
                ItemIsActive = j.ItemIsActive,
                WarehouseInput = j.WarehouseInput,
                WarehouseId = j.WarehouseId,
                WarehouseCode = j.WarehouseCode,
                WarehouseName = j.WarehouseName,
                BranchCode = j.BranchCode,
                MinQuantityBase = j.MinQuantityBase,
                MaxQuantityBase = j.MaxQuantityBase,
                Remove = j.IsRemove,
                HasLevel = j.HasLevel,
                CurrentMinBase = j.CurrentMinBase,
                CurrentMaxBase = j.CurrentMaxBase,
            }).ToList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private sealed class ImportCountsRow
    {
        public int Added { get; init; }
        public int Changed { get; init; }
        public int Removed { get; init; }
        public int Unchanged { get; init; }
        public int Skipped { get; init; }

        /// <summary>The procedure's S13 sentence ("Stock levels imported: ..." / "Nothing was imported: ..."): the answer's message.</summary>
        public string? Message { get; init; }
    }

    public async Task<StockLevelImportResult> ImportAsync(
        IReadOnlyList<StockLevelFileRow> rows, string? fileName, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Rows", ToImportTable(rows).AsTableValuedParameter(ImportTypeName));
        parameters.Add("@FileName", Cut(Trimmed(fileName), FileNameLength), DbType.String, size: FileNameLength);
        parameters.Add("@UserId", userId, DbType.Int32);

        return await QueryMultipleAsync("inventory.usp_ItemWarehouseLevel_Import", parameters, _connectionFactory.BatchCommandTimeout,
            async multi =>
            {
                var outcomes = (await multi.ReadAsync<StockLevelImportRowOutcome>()).AsList();
                var counts = await multi.ReadSingleOrDefaultAsync<ImportCountsRow>() ?? new ImportCountsRow();
                return new StockLevelImportResult
                {
                    Added = counts.Added,
                    Changed = counts.Changed,
                    Removed = counts.Removed,
                    Unchanged = counts.Unchanged,
                    Skipped = counts.Skipped,
                    Rows = outcomes,
                    Message = counts.Message ?? string.Empty,
                };
            }, cancellationToken);
    }

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    private static StockLevelRowDto ToDto(LevelRow r) => new()
    {
        ItemId = r.ItemId,
        ItemCode = r.ItemCode ?? string.Empty,
        ItemName = r.ItemName ?? string.Empty,
        ItemIsActive = r.ItemIsActive,
        ItemFamilyName = r.ItemFamilyName,
        BrandName = r.BrandName,
        WarehouseId = r.WarehouseId,
        WarehouseCode = r.WarehouseCode ?? string.Empty,
        WarehouseName = r.WarehouseName ?? string.Empty,
        WarehouseIsActive = r.WarehouseIsActive,
        BranchId = r.BranchId,
        BranchCode = r.BranchCode,
        BranchName = r.BranchName,
        HasLevel = r.HasLevel,
        MinQuantityBase = r.MinQuantityBase,
        MaxQuantityBase = r.MaxQuantityBase,
        OnHandBase = r.OnHandBase,
        InOnTheWayBase = r.InOnTheWayBase,
        InToDispatchBase = r.InToDispatchBase,
        OutToDispatchBase = r.OutToDispatchBase,
        ProjectedBase = r.ProjectedBase,
        ToReachMaxBase = r.ToReachMaxBase,
        Status = r.Status ?? (r.HasLevel ? StockLevelStatuses.Ok : StockLevelStatuses.NoLevel),
        UpdatedAtUtc = r.UpdatedAtUtc,
        UpdatedByName = r.UpdatedByName,
        RowVersion = r.RowVersion is { Length: > 0 } version ? Convert.ToBase64String(version) : null,
    };

    /// <summary>
    /// inventory.tvp_ItemWarehouseLevel (WarehouseId, MinQuantityBase, MaxQuantityBase, RowVersion). COLUMN ORDER IS THE
    /// TYPE'S ORDER AND IS LOAD-BEARING (a table-valued parameter is sent positionally); WarehouseId is its key, so the
    /// service refuses a warehouse sent twice before this.
    /// </summary>
    private static DataTable ToLevelTable(IReadOnlyList<ItemWarehouseLevelInput> levels)
    {
        var table = new DataTable();
        table.Columns.Add("WarehouseId", typeof(int));
        table.Columns.Add("MinQuantityBase", typeof(int));
        table.Columns.Add("MaxQuantityBase", typeof(int));
        table.Columns.Add("RowVersion", typeof(byte[]));

        foreach (var level in levels)
        {
            table.Rows.Add(
                level.WarehouseId,
                (object?)level.MinQuantityBase ?? DBNull.Value,
                (object?)level.MaxQuantityBase ?? DBNull.Value,
                (object?)level.RowVersion ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>
    /// inventory.tvp_ItemWarehouseLevelImport (RowNumber, ItemRef, WarehouseRef, MinQuantityBase, MaxQuantityBase,
    /// IsRemove, ParseError), in the type's order; RowNumber is its key (the service refuses a row number twice).
    /// </summary>
    private static DataTable ToImportTable(IReadOnlyList<StockLevelFileRow> rows)
    {
        var table = new DataTable();
        table.Columns.Add("RowNumber", typeof(int));
        table.Columns.Add("ItemRef", typeof(string));
        table.Columns.Add("WarehouseRef", typeof(string));
        table.Columns.Add("MinQuantityBase", typeof(int));
        table.Columns.Add("MaxQuantityBase", typeof(int));
        table.Columns.Add("IsRemove", typeof(bool));
        table.Columns.Add("ParseError", typeof(string));

        foreach (var row in rows)
        {
            table.Rows.Add(
                row.RowNumber,
                (object?)Cut(Trimmed(row.ItemRef), ItemRefLength) ?? DBNull.Value,
                (object?)Cut(Trimmed(row.WarehouseRef), WarehouseRefLength) ?? DBNull.Value,
                (object?)row.MinQuantityBase ?? DBNull.Value,
                (object?)row.MaxQuantityBase ?? DBNull.Value,
                row.IsRemove,
                (object?)Cut(Trimmed(row.ParseError), ParseErrorLength) ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>One procedure call, run again if SQL Server made it the deadlock victim (each write is one transaction).</summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>A call whose result sets are read by <paramref name="read"/>, with the same retry and refusal handling.</summary>
    private async Task<T> QueryMultipleAsync<T>(
        string procedure, object parameters, int? commandTimeout, Func<SqlMapper.GridReader, Task<T>> read,
        CancellationToken cancellationToken)
    {
        try
        {
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                    procedure, parameters, commandTimeout: commandTimeout,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
                var result = await read(multi);

                // Drain what is left, so an error raised after the last set read still reaches us as an exception.
                while (!multi.IsConsumed)
                {
                    await multi.ReadAsync();
                }

                return result;
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string? Cut(string? value, int length) => value is { Length: > 0 } text && text.Length > length ? text[..length] : value;
}
