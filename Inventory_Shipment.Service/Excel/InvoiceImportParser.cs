using System.Globalization;
using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Service.Excel;

/// <summary>Raised when the file itself cannot be read as an import file. Never used for a bad ROW.</summary>
public sealed class InvoiceImportFileException : Exception
{
    public InvoiceImportFileException(string message) : base(message)
    {
    }

    public InvoiceImportFileException(string message, Exception innerException) : base(message, innerException)
    {
    }
}

/// <summary>
/// Reads an .xlsx into rows. It does not judge them.
///
/// THE LINE BETWEEN THIS AND THE DATABASE IS THE WHOLE DESIGN. This class decides only what the
/// FILE says: which column is which, which cells are empty, and whether "5%" is a number. Whether an
/// item exists, whether a unit belongs to it, whether a price can be found — none of that is here,
/// because it is all joins against master data and the procedure does it for two thousand rows in one
/// call. A parser that started deciding would be a second rulebook drifting away from the first.
///
/// SO NOTHING HERE REJECTS A ROW. A quantity of "abc" is passed on as NULL with the text beside it,
/// and the procedure writes "Quantity 'abc' is not a number." in the same words it uses for every
/// other bad quantity. The only thing this refuses is the FILE: not .xlsx, too big, or without the
/// two columns that make it an import file at all.
///
/// COLUMNS ARE FOUND BY THEIR HEADING, not by position. People reorder columns, and a parser reading
/// column D would silently import discounts as prices; matching on the text costs one dictionary and
/// removes the whole class of failure.
/// </summary>
public sealed class InvoiceImportParser
{
    /// <summary>Big enough for any real invoice, small enough that a wrong file is refused rather than parsed for a minute.</summary>
    public const long MaxFileBytes = 10 * 1024 * 1024;

    /// <summary>The most data rows one file may carry. Beyond this it is a data load, not an invoice.</summary>
    public const int MaxDataRows = 2000;

    public const string TemplateMismatchMessage =
        "The file does not match the import template. Download the template and try again.";

    /// <summary>
    /// The headings, and the aliases people actually type.
    ///
    /// Matched case- and space-insensitively (see <see cref="Normalize"/>), so "Item Code/Barcode",
    /// "ITEM CODE" and "itemcode" are one heading. The aliases exist because the template says
    /// "Item Code / Barcode" while half the files in the world say "Item Code".
    /// </summary>
    private static readonly Dictionary<string, string> HeaderAliases = new(StringComparer.Ordinal)
    {
        ["itemcode/barcode"] = ColumnItem,
        ["itemcode"] = ColumnItem,
        ["barcode"] = ColumnItem,
        ["itemcodebarcode"] = ColumnItem,
        ["unit"] = ColumnUnit,
        ["unitname"] = ColumnUnit,
        ["warehouse"] = ColumnWarehouse,
        ["warehousecode"] = ColumnWarehouse,
        ["quantity"] = ColumnQuantity,
        ["qty"] = ColumnQuantity,
        ["unitprice"] = ColumnPrice,
        ["price"] = ColumnPrice,
        ["discount%"] = ColumnDiscount,
        ["discount"] = ColumnDiscount,
        ["discountpercent"] = ColumnDiscount,
        ["expirydate"] = ColumnExpiry,
        ["expiry"] = ColumnExpiry,
        ["notes"] = ColumnNotes,
        ["note"] = ColumnNotes,
        ["documenttype"] = ColumnDocumentType,
        ["type"] = ColumnDocumentType,
        ["doctype"] = ColumnDocumentType,
        ["invoicetype"] = ColumnDocumentType,
        // The common template's price heading; the older "Unit Price" files still match above.
        ["unitprice/cost"] = ColumnPrice,
        ["cost"] = ColumnPrice,
        ["unitcost"] = ColumnPrice,
    };

    internal const string ColumnItem = "Item";
    internal const string ColumnUnit = "Unit";
    internal const string ColumnWarehouse = "Warehouse";
    internal const string ColumnQuantity = "Quantity";
    internal const string ColumnPrice = "Price";
    internal const string ColumnDiscount = "Discount";
    internal const string ColumnExpiry = "Expiry";
    internal const string ColumnNotes = "Notes";
    internal const string ColumnDocumentType = "DocumentType";

    /// <summary>
    /// Date formats accepted from a TEXT cell.
    ///
    /// A real date cell is read as a date and never reaches these. This list is for the columns
    /// somebody formatted as text, where "05/09/2026" is ambiguous and the day-first reading is the
    /// one this application's users mean. Anything else is passed on unparsed and the procedure
    /// names it, rather than being guessed at into the wrong year.
    /// </summary>
    private static readonly string[] DateFormats =
        ["dd/MM/yyyy", "d/M/yyyy", "yyyy-MM-dd", "dd-MM-yyyy", "d-M-yyyy", "dd.MM.yyyy"];

    /// <summary>
    /// Reads the first worksheet of an .xlsx.
    /// </summary>
    /// <exception cref="InvoiceImportFileException">The file is not a readable import file.</exception>
    public IReadOnlyList<InvoiceImportRow> Parse(Stream stream)
    {
        XLWorkbook workbook;
        try
        {
            workbook = new XLWorkbook(stream);
        }
        catch (Exception ex) when (ex is not InvoiceImportFileException)
        {
            // A .csv renamed to .xlsx, a corrupt upload, an .xls from 2003: all arrive here as some
            // ClosedXML/OpenXML exception whose text is about zip archives. The person needs to be
            // told about their file, not about the format it is stored in — but the original is kept
            // as the inner exception, because a genuinely corrupt upload is worth having in a log.
            throw new InvoiceImportFileException(
                "The file could not be opened as an Excel workbook (.xlsx). " + TemplateMismatchMessage, ex);
        }

        using (workbook)
        {
            var sheet = workbook.Worksheets.FirstOrDefault()
                ?? throw new InvoiceImportFileException("The workbook has no worksheets.");

            var (headerRow, columns) = FindHeader(sheet);

            // The two columns without which the file is not an import file. Everything else has a
            // documented default, so its absence is a choice rather than a mistake.
            if (!columns.ContainsKey(ColumnItem) || !columns.ContainsKey(ColumnQuantity))
            {
                throw new InvoiceImportFileException(TemplateMismatchMessage);
            }

            return ReadRows(sheet, headerRow, columns);
        }
    }

    /// <summary>
    /// Finds the header row and maps each known heading to its column number.
    ///
    /// THE FIRST ROW CONTAINING "Item Code" WINS, rather than row 1 — files arrive with a title, a
    /// company name or a blank row above the table, and demanding row 1 would reject a file that is
    /// otherwise perfect. Only the first 25 rows are searched: past that it is not a header.
    /// </summary>
    private static (int HeaderRow, Dictionary<string, int> Columns) FindHeader(IXLWorksheet sheet)
    {
        var used = sheet.RangeUsed();
        if (used is null)
        {
            throw new InvoiceImportFileException("The worksheet is empty.");
        }

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
                if (heading.Length == 0 || !HeaderAliases.TryGetValue(heading, out var name))
                {
                    continue;
                }

                // First match wins: a file with the heading twice is answered by the leftmost, which
                // is the one a person reading the sheet would take it to mean.
                columns.TryAdd(name, columnNumber);
            }

            if (columns.ContainsKey(ColumnItem))
            {
                return (rowNumber, columns);
            }
        }

        throw new InvoiceImportFileException(TemplateMismatchMessage);
    }

    private static IReadOnlyList<InvoiceImportRow> ReadRows(
        IXLWorksheet sheet, int headerRow, Dictionary<string, int> columns)
    {
        var used = sheet.RangeUsed()!;
        var lastRow = used.RangeAddress.LastAddress.RowNumber;
        var rows = new List<InvoiceImportRow>();

        for (var rowNumber = headerRow + 1; rowNumber <= lastRow; rowNumber++)
        {
            // A blank row is not a row. Files carry them between groups and at the end, and counting
            // them would report a file of twelve lines as one of two hundred.
            if (columns.Values.All(c => sheet.Cell(rowNumber, c).IsEmpty()))
            {
                continue;
            }

            if (rows.Count >= MaxDataRows)
            {
                throw new InvoiceImportFileException(
                    $"The file has more than {MaxDataRows} rows. Split it and import the parts separately.");
            }

            var (quantity, rawQuantity) = ReadNumber(Cell(sheet, rowNumber, columns, ColumnQuantity));
            var (price, _) = ReadNumber(Cell(sheet, rowNumber, columns, ColumnPrice));
            var (discount, _) = ReadNumber(Cell(sheet, rowNumber, columns, ColumnDiscount), allowPercent: true);
            var (expiry, rawExpiry) = ReadDate(Cell(sheet, rowNumber, columns, ColumnExpiry));

            rows.Add(new InvoiceImportRow
            {
                // THE EXCEL ROW NUMBER, not the index in this list. Every message ends up in front of
                // somebody with the file open, and "row 5" has to be the row their cursor lands on.
                RowNumber = rowNumber,
                ItemRef = Text(sheet, rowNumber, columns, ColumnItem),
                UnitName = Text(sheet, rowNumber, columns, ColumnUnit),
                WarehouseRef = Text(sheet, rowNumber, columns, ColumnWarehouse),
                Quantity = quantity,
                RawQuantity = rawQuantity,
                UnitPrice = price,
                DiscountPercent = discount,
                ExpiryDate = expiry,
                RawExpiryDate = rawExpiry,
                Notes = Text(sheet, rowNumber, columns, ColumnNotes),
                DocumentTypeCode = Text(sheet, rowNumber, columns, ColumnDocumentType),
            });
        }

        return rows;
    }

    private static IXLCell? Cell(IXLWorksheet sheet, int rowNumber, Dictionary<string, int> columns, string name)
        => columns.TryGetValue(name, out var columnNumber) ? sheet.Cell(rowNumber, columnNumber) : null;

    private static string? Text(IXLWorksheet sheet, int rowNumber, Dictionary<string, int> columns, string name)
    {
        var value = Cell(sheet, rowNumber, columns, name)?.GetString().Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }

    /// <summary>
    /// A number from a numeric cell, or from text that reads as one.
    ///
    /// THE RAW TEXT COMES BACK WITH THE FAILURE so the procedure can quote it. An empty cell is NOT a
    /// failure — it is "not given", which every numeric column here has a defined default for — so it
    /// returns two nulls and no complaint.
    ///
    /// InvariantCulture, then the current culture: a file written on a machine using commas for
    /// decimals is common enough to be worth the second attempt, and trying invariant first means a
    /// server's own locale cannot change how "1.5" is read.
    /// </summary>
    private static (decimal? Value, string? Raw) ReadNumber(IXLCell? cell, bool allowPercent = false)
    {
        if (cell is null || cell.IsEmpty())
        {
            return (null, null);
        }

        if (cell.DataType == XLDataType.Number)
        {
            var number = cell.GetDouble();

            // Excel stores a percent-formatted 5% as 0.05. Read as 0.05 it becomes a discount of a
            // twentieth of one percent, which is not what anybody typed.
            if (allowPercent && cell.Style.NumberFormat.Format.Contains('%'))
            {
                number *= 100;
            }

            return ((decimal)number, null);
        }

        var text = cell.GetString().Trim();
        if (text.Length == 0)
        {
            return (null, null);
        }

        var candidate = allowPercent ? text.TrimEnd('%', ' ') : text;

        if (decimal.TryParse(candidate, NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed)
            || decimal.TryParse(candidate, NumberStyles.Number, CultureInfo.CurrentCulture, out parsed))
        {
            return (parsed, null);
        }

        return (null, text);
    }

    /// <summary>A date from a date cell, or from text in one of the accepted formats. Empty is not a failure.</summary>
    private static (DateTime? Value, string? Raw) ReadDate(IXLCell? cell)
    {
        if (cell is null || cell.IsEmpty())
        {
            return (null, null);
        }

        if (cell.DataType == XLDataType.DateTime)
        {
            return (cell.GetDateTime().Date, null);
        }

        var text = cell.GetString().Trim();
        if (text.Length == 0)
        {
            return (null, null);
        }

        return DateTime.TryParseExact(text, DateFormats, CultureInfo.InvariantCulture,
            DateTimeStyles.None, out var parsed)
            ? (parsed.Date, null)
            : (null, text);
    }

    /// <summary>Lower-cased with every space removed, so "Discount %" and "discount%" are one heading.</summary>
    private static string Normalize(string value)
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
