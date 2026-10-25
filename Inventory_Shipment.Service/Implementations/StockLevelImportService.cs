using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Stock levels from an Excel file (script 91, rules S11-S13): one row = one item's Min / Max in one warehouse, or its
/// removal.
///
/// THE PATTERN OF THE OTHER IMPORTS: the template, a validate that reads the file and judges every row without writing,
/// an error report built from the rows the client posts back, and the import of the rows the client posts back. The file
/// is never kept on the server: what is imported is what the person was shown.
///
/// ONE JUDGEMENT, IN THE DATABASE (inventory.fn_ItemWarehouseLevel_ImportJudge), read by the check AND by the import,
/// which judges the rows again inside its one transaction: a level changed by somebody else between the two becomes
/// "No change" or an Error there, never a silent overwrite of a row the preview did not show. Every Valid and Warning row
/// is written together; Error and Unchanged rows are skipped.
/// </summary>
public sealed class StockLevelImportService : IStockLevelImportService
{
    private const string InvalidFileCode = "INVALID_FILE";
    private const string ForbiddenCode = "FORBIDDEN";

    private static readonly CultureInfo Numbers = CultureInfo.InvariantCulture;

    private readonly IStockLevelRepository _levels;
    private readonly StockLevelImportParser _parser;
    private readonly ILogger<StockLevelImportService> _logger;

    public StockLevelImportService(
        IStockLevelRepository levels, StockLevelImportParser parser, ILogger<StockLevelImportService> logger)
    {
        _levels = levels;
        _parser = parser;
        _logger = logger;
    }

    public Result<(byte[] Content, string FileName)> GenerateTemplate(IReadOnlySet<string> permissions)
        => permissions.Contains(Permissions.Inventory.StockLevelsEdit)
            ? Result<(byte[], string)>.Success((StockLevelImportWorkbooks.GenerateTemplate(), StockLevelImportWorkbooks.TemplateFileName))
            : Forbidden<(byte[], string)>();

    public Result<(byte[] Content, string FileName)> GenerateErrorReport(
        IReadOnlyList<StockLevelImportRow> rows, IReadOnlySet<string> permissions)
        => permissions.Contains(Permissions.Inventory.StockLevelsEdit)
            ? Result<(byte[], string)>.Success(
                (StockLevelImportWorkbooks.GenerateErrorReport(rows ?? []), StockLevelImportWorkbooks.ErrorReportFileName))
            : Forbidden<(byte[], string)>();

    /* ── validation ───────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<StockLevelImportValidation>> ValidateAsync(
        Stream file, string fileName, long fileLength, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsEdit))
        {
            return Forbidden<StockLevelImportValidation>();
        }

        // The file's own problems, in the order a person would fix them (3.5.2).
        if (!fileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
        {
            return InvalidFile("The file must be an Excel workbook (.xlsx).");
        }

        if (fileLength > StockLevelImportParser.MaxFileBytes)
        {
            return InvalidFile($"The file is larger than {StockLevelImportParser.MaxFileBytes / (1024 * 1024)} MB.");
        }

        if (fileLength <= 0)
        {
            return InvalidFile(StockLevelImportParser.NoRowsMessage);
        }

        IReadOnlyList<StockLevelFileRow> fileRows;
        try
        {
            fileRows = _parser.Parse(file);
        }
        catch (StockLevelImportFileException ex)
        {
            if (ex.InnerException is not null)
            {
                _logger.LogInformation(ex.InnerException, "Stock levels import: {FileName} could not be opened", fileName);
            }

            return InvalidFile(ex.Message);
        }

        IReadOnlyList<StockLevelImportRow> judged;
        try
        {
            judged = await _levels.ImportCheckAsync(fileRows, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = StockLevelService.Describe(ex);
            return Result<StockLevelImportValidation>.Failure(failure.Type, failure.Message, failure.Code);
        }

        // What the file had in the cells that did not read: the judgement knows only the sentence, the page shows the text.
        var byRow = fileRows.ToDictionary(r => r.RowNumber);
        var rows = judged
            .Select(j => byRow.TryGetValue(j.RowNumber, out var raw) ? WithRaw(j, raw) : j)
            .OrderBy(r => r.RowNumber)
            .ToList();

        var counts = CountRows(rows);
        _logger.LogInformation(
            "Stock levels import validated {FileName}: {Rows} rows, {Set} to set, {Remove} to remove, {Unchanged} unchanged, {Warnings} warnings, {Errors} errors",
            fileName, rows.Count, counts.Set, counts.Remove, counts.Unchanged, counts.Warnings, counts.Errors);

        return Result<StockLevelImportValidation>.Success(new StockLevelImportValidation
        {
            FileName = fileName,
            Rows = rows,
            Counts = counts,
        });
    }

    /* ── the import ───────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<StockLevelImportResult>> ImportAsync(
        StockLevelImportRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.StockLevelsEdit))
        {
            return Forbidden<StockLevelImportResult>();
        }

        var posted = request.Rows ?? [];
        if (posted.Count == 0)
        {
            return Result<StockLevelImportResult>.Failure(ErrorType.Validation, StockLevelImportParser.NoRowsMessage, "VALIDATION");
        }

        if (posted.Count > StockLevelImportParser.MaxRows)
        {
            return Result<StockLevelImportResult>.Failure(ErrorType.Validation, StockLevelImportParser.TooManyRowsMessage, "VALIDATION");
        }

        // The table type's key is the row number: one row sent twice could never be judged.
        if (posted.GroupBy(r => r.RowNumber).Any(g => g.Count() > 1))
        {
            return Result<StockLevelImportResult>.Failure(ErrorType.Validation, "Each row once.", "VALIDATION");
        }

        // The rows as the FILE had them: what the person typed, and the sentence of a cell that did not read. What they
        // resolved to is judged again by the database, inside the import's own transaction.
        var rows = posted.Select(r => new StockLevelFileRow
        {
            RowNumber = r.RowNumber,
            ItemRef = r.ItemInput,
            WarehouseRef = r.WarehouseInput,
            MinQuantityBase = r.MinQuantityBase,
            MaxQuantityBase = r.MaxQuantityBase,
            IsRemove = r.Remove,
            ParseError = r.ParseError,
        }).ToList();

        StockLevelImportResult result;
        try
        {
            result = await _levels.ImportAsync(rows, request.FileName, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = StockLevelService.Describe(ex);
            return Result<StockLevelImportResult>.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation(
            "Stock levels imported from {FileName} by user {UserId}: {Added} added, {Changed} changed, {Removed} removed, {Unchanged} unchanged, {Skipped} skipped",
            request.FileName, userId, result.Added, result.Changed, result.Removed, result.Unchanged, result.Skipped);

        return Result<StockLevelImportResult>.Success(new StockLevelImportResult
        {
            Added = result.Added,
            Changed = result.Changed,
            Removed = result.Removed,
            Unchanged = result.Unchanged,
            Skipped = result.Skipped,
            Rows = result.Rows,
            // The sentence is the procedure's (one place, as every message); built here only if an older body sent none.
            Message = string.IsNullOrWhiteSpace(result.Message) ? ResultMessage(result) : result.Message,
        });
    }

    /// <summary>
    /// S13: "Stock levels imported: {a} added, {c} changed, {r} removed; {u} rows without a change and {e} rows with errors
    /// skipped." - a part that is 0 is left out; nothing written: "Nothing was imported: every row is unchanged or has an
    /// error." The FALLBACK only: usp_ItemWarehouseLevel_Import builds the same sentence (its result 2's Message), which
    /// is the one answered; the numbers here are written the way the procedure writes them (no thousands separator).
    /// </summary>
    internal static string ResultMessage(StockLevelImportResult result)
    {
        if (result.Added + result.Changed + result.Removed == 0)
        {
            return "Nothing was imported: every row is unchanged or has an error.";
        }

        var done = new List<string>(3);
        if (result.Added > 0)
        {
            done.Add($"{Number(result.Added)} added");
        }

        if (result.Changed > 0)
        {
            done.Add($"{Number(result.Changed)} changed");
        }

        if (result.Removed > 0)
        {
            done.Add($"{Number(result.Removed)} removed");
        }

        var skipped = new List<string>(2);
        if (result.Unchanged > 0)
        {
            skipped.Add($"{Number(result.Unchanged)} {Rows(result.Unchanged)} without a change");
        }

        if (result.Skipped > 0)
        {
            skipped.Add($"{Number(result.Skipped)} {Rows(result.Skipped)} with errors");
        }

        var message = "Stock levels imported: " + string.Join(", ", done);
        return skipped.Count == 0
            ? message + "."
            : $"{message}; {string.Join(" and ", skipped)} skipped.";
    }

    /* ── helpers ──────────────────────────────────────────────────────────────────────────────── */

    private static StockLevelImportRow WithRaw(StockLevelImportRow judged, StockLevelFileRow file) => new()
    {
        RowNumber = judged.RowNumber,
        Status = judged.Status,
        Action = judged.Action,
        Message = judged.Message,
        ItemInput = judged.ItemInput ?? file.ItemRef,
        ItemId = judged.ItemId,
        ItemCode = judged.ItemCode,
        ItemName = judged.ItemName,
        ItemIsActive = judged.ItemIsActive,
        WarehouseInput = judged.WarehouseInput ?? file.WarehouseRef,
        WarehouseId = judged.WarehouseId,
        WarehouseCode = judged.WarehouseCode,
        WarehouseName = judged.WarehouseName,
        BranchCode = judged.BranchCode,
        MinQuantityBase = judged.MinQuantityBase ?? file.MinQuantityBase,
        MaxQuantityBase = judged.MaxQuantityBase ?? file.MaxQuantityBase,
        Remove = judged.Remove || file.IsRemove,
        RawMin = file.RawMin,
        RawMax = file.RawMax,
        RawRemove = file.RawRemove,
        ParseError = file.ParseError,
        HasLevel = judged.HasLevel,
        CurrentMinBase = judged.CurrentMinBase,
        CurrentMaxBase = judged.CurrentMaxBase,
    };

    private static StockLevelImportCounts CountRows(IReadOnlyList<StockLevelImportRow> rows)
    {
        static bool Usable(StockLevelImportRow r)
            => r.Status is StockLevelImportStatus.Valid or StockLevelImportStatus.Warning;

        return new StockLevelImportCounts
        {
            Set = rows.Count(r => Usable(r) && r.Action == StockLevelImportActions.Set),
            Remove = rows.Count(r => Usable(r) && r.Action == StockLevelImportActions.Remove),
            Unchanged = rows.Count(r => r.Status == StockLevelImportStatus.Unchanged),
            Warnings = rows.Count(r => r.Status == StockLevelImportStatus.Warning),
            Errors = rows.Count(r => r.Status == StockLevelImportStatus.Error),
        };
    }

    private static string Number(int value) => value.ToString(Numbers);

    private static string Rows(int value) => value == 1 ? "row" : "rows";

    private static Result<T> Forbidden<T>()
        => Result<T>.Failure(
            ErrorType.Forbidden, $"This action needs the {Permissions.Inventory.StockLevelsEdit} permission.", ForbiddenCode);

    private static Result<StockLevelImportValidation> InvalidFile(string message)
        => Result<StockLevelImportValidation>.Failure(ErrorType.Validation, message, InvalidFileCode);
}
