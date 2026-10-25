using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Stock levels per warehouse (script 91): an item's Min / Max in one warehouse at the bottom of the tree, and where the
/// warehouse stands for it (on hand, what released transfer orders bring and take, Projected).
///
/// THE RULES ARE THE PROCEDURES'. A leaf, never On the way, an active warehouse for a new or changed level, Max not below
/// Min, the row versions - each is refused by the procedure with its sentence, shown as it comes. This service checks the
/// permission, refuses what the table types cannot carry (a warehouse twice: the type's key) and a row version that cannot
/// be one, and answers the item's rows again after a change: the card redraws from the server's figures, never from what
/// it sent.
///
/// VIEWING IS NEVER LIMITED by warehouse (script 92, W3): the list, the company view and the history read every level.
/// </summary>
public sealed class StockLevelService : IStockLevelService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string InvalidRowVersionMessage = "The row version is not valid. Reload the page and try again.";

    /// <summary>The work after the commit never stops halfway (90's AfterCommit): the change took place.</summary>
    private static readonly CancellationToken AfterCommit = CancellationToken.None;

    private static readonly CultureInfo Numbers = CultureInfo.InvariantCulture;

    /// <summary>The company view's statuses (the page offers Below Min and every item; the API takes the three).</summary>
    private static readonly string[] CompanyStatuses = [StockLevelStatuses.BelowMin, StockLevelStatuses.AboveMax, StockLevelStatuses.Ok];

    private readonly IStockLevelRepository _levels;
    private readonly ILogger<StockLevelService> _logger;

    public StockLevelService(IStockLevelRepository levels, ILogger<StockLevelService> logger)
    {
        _levels = levels;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<StockLevelListResult>> SearchAsync(
        StockLevelQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsView))
        {
            return Forbidden<StockLevelListResult>(Permissions.Inventory.StockLevelsView);
        }

        try
        {
            var (rows, totals) = await _levels.SearchAsync(query, cancellationToken);
            return Result<StockLevelListResult>.Success(new StockLevelListResult { Rows = rows, Totals = totals });
        }
        catch (BusinessRuleException ex)
        {
            // An unknown status is the procedure's own sentence (56000 → 400).
            return Failure<StockLevelListResult>(ex);
        }
    }

    public async Task<Result<CompanyStockLevelListResult>> CompanySearchAsync(
        CompanyStockLevelQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsView))
        {
            return Forbidden<CompanyStockLevelListResult>(Permissions.Inventory.StockLevelsView);
        }

        if (!string.IsNullOrWhiteSpace(query.Status) && !CompanyStatuses.Contains(query.Status.Trim(), StringComparer.Ordinal))
        {
            return Result<CompanyStockLevelListResult>.Failure(
                ErrorType.Validation, "Unknown status: choose Below Min, Above Max or OK.", "VALIDATION");
        }

        try
        {
            return Result<CompanyStockLevelListResult>.Success(await _levels.CompanySearchAsync(query, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<CompanyStockLevelListResult>(ex);
        }
    }

    public async Task<Result<IReadOnlyList<StockLevelHistoryDto>>> HistoryAsync(
        int itemId, int warehouseId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsView))
        {
            return Forbidden<IReadOnlyList<StockLevelHistoryDto>>(Permissions.Inventory.StockLevelsView);
        }

        try
        {
            return Result<IReadOnlyList<StockLevelHistoryDto>>.Success(await _levels.HistoryAsync(itemId, warehouseId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<StockLevelHistoryDto>>(ex);
        }
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        StockLevelQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await SearchAsync(query, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? "The stock levels could not be read.", read.Code ?? "VALIDATION");
        }

        _logger.LogInformation("Stock levels exported: {Rows} rows", read.Value.Rows.Count);
        return Result<(byte[], string)>.Success(
            (StockLevelImportWorkbooks.BuildExport(read.Value.Rows), StockLevelImportWorkbooks.ExportFileName));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<SetStockLevelsResult>> SetAsync(
        int itemId, SetStockLevelsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsEdit))
        {
            return Forbidden<SetStockLevelsResult>(Permissions.Inventory.StockLevelsEdit);
        }

        var levels = request.Levels ?? [];

        // An empty row ("levels": [null]) passes the model binding (it checks properties, not the elements of a list):
        // refused here, as 90's transfer lines are, instead of ending in a NullReferenceException and a 500.
        var empty = levels.ToList().FindIndex(l => l is null);
        if (empty >= 0)
        {
            return Result<SetStockLevelsResult>.Failure(
                ErrorType.Validation, $"Level {(empty + 1).ToString(Numbers)} of the request is empty.", "VALIDATION");
        }

        // The table type's key is the warehouse: one warehouse sent twice could never be one row.
        if (levels.GroupBy(l => l.WarehouseId).Any(g => g.Count() > 1))
        {
            return Result<SetStockLevelsResult>.Failure(ErrorType.Validation, "Each warehouse once.", "VALIDATION");
        }

        var inputs = new List<ItemWarehouseLevelInput>(levels.Count);
        foreach (var level in levels)
        {
            if (!TryRowVersion(level.RowVersion, out var rowVersion))
            {
                return Result<SetStockLevelsResult>.Failure(ErrorType.Validation, InvalidRowVersionMessage, "VALIDATION");
            }

            inputs.Add(new ItemWarehouseLevelInput(level.WarehouseId, level.MinQuantityBase, level.MaxQuantityBase, rowVersion));
        }

        try
        {
            // An empty list is the procedure's own refusal: "Choose at least one warehouse."
            await _levels.SetAsync(itemId, inputs, Source(request.Source), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<SetStockLevelsResult>(ex);
        }

        _logger.LogInformation("Stock levels of item {ItemId} set in {Count} warehouse(s) by user {UserId}", itemId, inputs.Count, userId);

        // Read after the commit whatever the caller does (AfterCommit, 90's Sec5): a closed tab or a proxy's timeout must
        // not turn a saved change into a 499, nor a failed read into a 500 - the person would type the change again.
        var rows = await ItemRowsAsync(itemId, AfterCommit);
        var itemCode = rows.FirstOrDefault()?.ItemCode;
        var count = inputs.Count;
        var message = $"{count.ToString("N0", Numbers)} stock level{(count == 1 ? string.Empty : "s")} saved"
                      + (string.IsNullOrEmpty(itemCode) ? "." : $" for {itemCode}.");

        return Result<SetStockLevelsResult>.Success(new SetStockLevelsResult { Rows = rows, Message = message });
    }

    public async Task<Result> RemoveAsync(
        int itemId, int warehouseId, string? rowVersion, string? source, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsEdit))
        {
            return Result.Failure(ErrorType.Forbidden, $"This action needs the {Permissions.Inventory.StockLevelsEdit} permission.", ForbiddenCode);
        }

        if (!TryRowVersion(rowVersion, out var version))
        {
            return Result.Failure(ErrorType.Validation, InvalidRowVersionMessage, "VALIDATION");
        }

        try
        {
            await _levels.RemoveAsync(itemId, warehouseId, version, Source(source), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Stock level of item {ItemId} at warehouse {WarehouseId} removed by user {UserId}", itemId, warehouseId, userId);
        return Result.Success();
    }

    /* ── shared ───────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The item's levels as its card reads them: every warehouse with a level, inactive warehouses and an inactive item
    /// included. A read that fails after the write - for any reason but a cancellation - answers no rows: the change
    /// itself went through, and the card reloads.
    /// </summary>
    private async Task<IReadOnlyList<StockLevelRowDto>> ItemRowsAsync(int itemId, CancellationToken cancellationToken)
    {
        try
        {
            var (rows, _) = await _levels.SearchAsync(new StockLevelQuery
            {
                ItemId = itemId,
                ActiveItemsOnly = false,
                IncludeInactiveWarehouses = true,
            }, cancellationToken);
            return rows;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Stock levels of item {ItemId} could not be read again after a change", itemId);
            return [];
        }
    }

    /// <summary>Where a change by hand was made: Stock Levels, else the item card (an import is never typed by hand).</summary>
    internal static string Source(string? source)
        => string.Equals(source?.Trim(), StockLevelSources.StockLevels, StringComparison.OrdinalIgnoreCase)
            ? StockLevelSources.StockLevels
            : StockLevelSources.ItemCard;

    /// <summary>Blank is "not sent" (null); anything else must be 8 bytes of base64, never silently read as not sent.</summary>
    internal static bool TryRowVersion(string? value, out byte[]? rowVersion)
    {
        rowVersion = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        var buffer = new byte[8];
        if (Convert.TryFromBase64String(value.Trim(), buffer, out var written) && written == 8)
        {
            rowVersion = buffer;
            return true;
        }

        return false;
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The levels' THROWs, classified (3.3.10): the item block's numbers. THE MESSAGE IS ALWAYS THE PROCEDURE'S ("LUB-01:
    /// Max cannot be less than Min.", "The stock level of TVS-APACHE-160 at LUB-01 was changed by another user. Reload and
    /// try again."); only the code is added. Script 92 adds its warehouse-access arm (50010 → 403).
    /// </summary>
    internal static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.ItemValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.ItemConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.ItemNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
    };

    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);
}
