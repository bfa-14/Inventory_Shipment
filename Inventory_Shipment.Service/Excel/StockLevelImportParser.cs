using System.Globalization;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;

namespace Inventory_Shipment.Service.Excel;

/// <summary>Raised when the file itself cannot be read as a stock levels file. Never used for a bad ROW.</summary>
public sealed class StockLevelImportFileException : Exception
{
    public StockLevelImportFileException(string message) : base(message)
    {
    }

    public StockLevelImportFileException(string message, Exception innerException) : base(message, innerException)
    {
    }
}

/// <summary>
/// Reads the stock levels workbook into rows (script 91). It does not judge them.
///
/// THE SAME LINE AS THE OTHER IMPORTS (ContainerChargeImportParser): this class decides only what the FILE says - which
/// column is which, which cells are empty, whether "20" is a whole number. Whether an item or a warehouse exists, is a
/// leaf, is active, whether Max is below Min or the row is unchanged is the database's (inventory.fn_ItemWarehouseLevel_
/// ImportJudge), so the check and the import judge alike. Nothing here rejects a row: a cell that will not read is passed
/// on as typed with its sentence in ParseError, which the judgement puts first. Only the FILE is refused: no worksheet,
/// not the template's columns, more than 20,000 rows, no rows.
///
/// COLUMNS ARE FOUND BY THEIR HEADING, not by position, and every other column is ignored: an export of Inventory › Stock
/// Levels (the five import columns first, then information columns) can be edited and imported back, and so can the
/// error report (Row, Status and Message are not headings of the import).
/// </summary>
public sealed class StockLevelImportParser
{
    /// <summary>A levels file is a few thousand rows: far below this.</summary>
    public const long MaxFileBytes = 5 * 1024 * 1024;

    /// <summary>The most data rows one file may carry; the import is one transaction.</summary>
    public const int MaxRows = 20_000;

    /// <summary>The template's data sheet. Read first when present; otherwise the first sheet.</summary>
    public const string DataSheetName = "Levels";

    public const string ColumnItem = "Item Code / Barcode";
    public const string ColumnWarehouse = "Warehouse";
    public const string ColumnMin = "Min (pcs)";
    public const string ColumnMax = "Max (pcs)";
    public const string ColumnRemove = "Remove";

    /// <summary>The headings in the template's order. The parser matches the text, never the position.</summary>
    public static readonly string[] TemplateHeaders = [ColumnItem, ColumnWarehouse, ColumnMin, ColumnMax, ColumnRemove];

    public const string NotTemplateMessage =
        "The file does not have the template's columns: Item Code / Barcode, Warehouse, Min (pcs), Max (pcs). "
        + "Download the template and copy your rows into it.";

    public static readonly string TooManyRowsMessage =
        $"The file has more than {MaxRows.ToString("N0", CultureInfo.InvariantCulture)} rows: split it.";

    public const string NoRowsMessage = "The file has no rows.";

    /// <summary>The headings and the aliases people type, lower case without spaces (see <see cref="Normalize"/>).</summary>
    private static readonly Dictionary<string, string> HeaderAliases = new(StringComparer.Ordinal)
    {
        ["itemcode/barcode"] = ColumnItem,
        ["itemcode"] = ColumnItem,
        ["item"] = ColumnItem,
        ["barcode"] = ColumnItem,
        ["warehouse"] = ColumnWarehouse,
        ["warehousecode"] = ColumnWarehouse,
        ["min(pcs)"] = ColumnMin,
        ["min"] = ColumnMin,
        ["minimum"] = ColumnMin,
        ["max(pcs)"] = ColumnMax,
        ["max"] = ColumnMax,
        ["maximum"] = ColumnMax,
        ["remove"] = ColumnRemove,
    };

    /// <summary>Digits only, an optional sign before them: "20", "+20", "-3" (refused as below 0 afterwards).</summary>
    private static readonly Regex WholeNumber = new(@"^[+-]?[0-9]+(?:\.0+)?$", RegexOptions.CultureInvariant);

    /// <exception cref="StockLevelImportFileException">The file is not a readable stock levels file.</exception>
    public IReadOnlyList<StockLevelFileRow> Parse(Stream stream)
    {
        XLWorkbook workbook;
        try
        {
            workbook = new XLWorkbook(stream);
        }
        catch (Exception ex) when (ex is not StockLevelImportFileException)
        {
            // A .csv renamed, a corrupt upload, an .xls: the person is told about their file, the cause is kept for the log.
            throw new StockLevelImportFileException("The file must be an Excel workbook (.xlsx).", ex);
        }

        using (workbook)
        {
            var sheet = workbook.Worksheets.FirstOrDefault(s => string.Equals(s.Name.Trim(), DataSheetName, StringComparison.OrdinalIgnoreCase))
                ?? workbook.Worksheets.FirstOrDefault()
                ?? throw new StockLevelImportFileException(NoRowsMessage);

            var (headerRow, columns) = FindHeader(sheet);
            var rows = ReadRows(sheet, headerRow, columns);
            return rows.Count == 0 ? throw new StockLevelImportFileException(NoRowsMessage) : rows;
        }
    }

    /// <summary>
    /// The first row, among the first 25, that holds the four columns of the template (Remove is optional): files arrive
    /// with a title above the table.
    /// </summary>
    private static (int HeaderRow, Dictionary<string, int> Columns) FindHeader(IXLWorksheet sheet)
    {
        var used = sheet.RangeUsed() ?? throw new StockLevelImportFileException(NoRowsMessage);

        var firstRow = used.RangeAddress.FirstAddress.RowNumber;
        var lastRow = Math.Min(used.RangeAddress.LastAddress.RowNumber, firstRow + 24);
        var firstColumn = used.RangeAddress.FirstAddress.ColumnNumber;
        var lastColumn = used.RangeAddress.LastAddress.ColumnNumber;

        for (var rowNumber = firstRow; rowNumber <= lastRow; rowNumber++)
        {
            var columns = new Dictionary<string, int>(StringComparer.Ordinal);

            for (var columnNumber = firstColumn; columnNumber <= lastColumn; columnNumber++)
            {
                var heading = Normalize(sheet.Cell(rowNumber, columnNumber).GetString());
                if (heading.Length > 0 && HeaderAliases.TryGetValue(heading, out var name))
                {
                    // The leftmost of a heading typed twice wins: the one a person reading the sheet would take.
                    columns.TryAdd(name, columnNumber);
                }
            }

            if (columns.ContainsKey(ColumnItem) && columns.ContainsKey(ColumnWarehouse)
                && columns.ContainsKey(ColumnMin) && columns.ContainsKey(ColumnMax))
            {
                return (rowNumber, columns);
            }
        }

        throw new StockLevelImportFileException(NotTemplateMessage);
    }

    private static List<StockLevelFileRow> ReadRows(IXLWorksheet sheet, int headerRow, Dictionary<string, int> columns)
    {
        var lastRow = sheet.RangeUsed()!.RangeAddress.LastAddress.RowNumber;
        var rows = new List<StockLevelFileRow>();

        for (var rowNumber = headerRow + 1; rowNumber <= lastRow; rowNumber++)
        {
            // A blank row is not a row: only the import's own columns count (an export's information columns do not).
            if (columns.Values.All(c => IsBlank(sheet.Cell(rowNumber, c))))
            {
                continue;
            }

            if (rows.Count >= MaxRows)
            {
                throw new StockLevelImportFileException(TooManyRowsMessage);
            }

            var (min, rawMin) = ReadQuantity(Cell(sheet, rowNumber, columns, ColumnMin));
            var (max, rawMax) = ReadQuantity(Cell(sheet, rowNumber, columns, ColumnMax));
            var (remove, rawRemove) = ReadRemove(Cell(sheet, rowNumber, columns, ColumnRemove));

            // S12.1: the first cell that does not read, in the order Min, Max, Remove.
            var parseError = rawMin is not null
                ? $"Min must be a whole number, 0 or more (the file has '{Quoted(rawMin)}')."
                : rawMax is not null
                    ? $"Max must be a whole number, 0 or more (the file has '{Quoted(rawMax)}')."
                    : rawRemove is not null
                        ? $"Remove must be Yes or empty (the file has '{Quoted(rawRemove)}')."
                        : null;

            rows.Add(new StockLevelFileRow
            {
                RowNumber = rowNumber,
                ItemRef = Text(sheet, rowNumber, columns, ColumnItem),
                WarehouseRef = Text(sheet, rowNumber, columns, ColumnWarehouse),
                MinQuantityBase = min,
                MaxQuantityBase = max,
                IsRemove = remove,
                RawMin = rawMin,
                RawMax = rawMax,
                RawRemove = rawRemove,
                ParseError = parseError,
            });
        }

        return rows;
    }

    private static bool IsBlank(IXLCell cell) => cell.IsEmpty() || cell.GetString().Trim().Length == 0;

    /// <summary>The longest text a sentence quotes from a cell.</summary>
    internal const int MaxQuotedLength = 100;

    /// <summary>
    /// A cell's text as a sentence quotes it: at most <see cref="MaxQuotedLength"/> characters, then "…". The sentence goes
    /// back and forth as the row's ParseError (300 characters at most: the table type's column and the request's limit),
    /// so a cell of a whole paragraph must not make the row, or the whole import posted back, unreadable.
    /// </summary>
    internal static string Quoted(string raw) => raw.Length <= MaxQuotedLength ? raw : raw[..MaxQuotedLength] + "…";

    private static IXLCell? Cell(IXLWorksheet sheet, int rowNumber, Dictionary<string, int> columns, string name)
        => columns.TryGetValue(name, out var columnNumber) ? sheet.Cell(rowNumber, columnNumber) : null;

    private static string? Text(IXLWorksheet sheet, int rowNumber, Dictionary<string, int> columns, string name)
    {
        var value = Cell(sheet, rowNumber, columns, name)?.GetString().Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }

    /// <summary>
    /// A quantity in pcs: a whole number, 0 or more, from a numeric cell or from text read with the invariant culture.
    /// An empty cell is "not given" (null, null); anything else that is not a whole number 0 or more comes back as
    /// (null, what the file has), so the row quotes it. Never the server's culture: the same file reads the same on
    /// every machine.
    /// </summary>
    private static (int? Value, string? Raw) ReadQuantity(IXLCell? cell)
    {
        if (cell is null || cell.IsEmpty())
        {
            return (null, null);
        }

        if (cell.DataType == XLDataType.Number)
        {
            var number = cell.GetDouble();
            return double.IsFinite(number) && number >= 0 && number <= int.MaxValue && Math.Floor(number) == number
                ? ((int)number, null)
                : (null, number.ToString(CultureInfo.InvariantCulture));
        }

        var text = cell.GetString().Trim();
        if (text.Length == 0)
        {
            return (null, null);
        }

        return WholeNumber.IsMatch(text)
               && decimal.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var parsed)
               && parsed >= 0 && parsed <= int.MaxValue
            ? ((int)parsed, null)
            : (null, text);
    }

    /// <summary>Remove: "Yes" (any case) removes the level; empty does not; anything else comes back as typed.</summary>
    private static (bool Value, string? Raw) ReadRemove(IXLCell? cell)
    {
        if (cell is null || cell.IsEmpty())
        {
            return (false, null);
        }

        var text = cell.GetString().Trim();
        if (text.Length == 0)
        {
            return (false, null);
        }

        return string.Equals(text, "Yes", StringComparison.OrdinalIgnoreCase) ? (true, null) : (false, text);
    }

    /// <summary>Lower-cased with every space removed, so "Min (pcs)" and "min(pcs)" are one heading.</summary>
    internal static string Normalize(string value)
    {
        Span<char> buffer = stackalloc char[value.Length];
        var length = 0;

        foreach (var character in value)
        {
            if (!char.IsWhiteSpace(character))
            {
                buffer[length++] = char.ToLowerInvariant(character);
            }
        }

        return new string(buffer[..length]);
    }
}
