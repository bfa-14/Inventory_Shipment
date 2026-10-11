using System.Globalization;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Excel;

/// <summary>Raised when the file itself cannot be read as a charge import file. Never used for a bad ROW.</summary>
public sealed class ContainerChargeImportFileException : Exception
{
    public ContainerChargeImportFileException(string message) : base(message)
    {
    }

    public ContainerChargeImportFileException(string message, Exception innerException) : base(message, innerException)
    {
    }
}

/// <summary>
/// Reads the container charges workbook into rows. It does not judge them.
///
/// THE SAME LINE AS THE INVOICE IMPORT (InvoiceImportParser): this class decides only what the FILE says —
/// which column is which, which cells are empty, whether "2,100.00" is a number and "05/10/2026" a date.
/// Whether a container exists, whether a charge type is active or a rate can be found is the service's,
/// against master data. Nothing here rejects a row: a value that will not read is passed on as null with
/// its text, and the message quotes it. Only the FILE is refused: not .xlsx, too many rows, or without the
/// three columns that make it a charge import (Container, Charge Type, Amount).
///
/// COLUMNS ARE FOUND BY THEIR HEADING, not by position, so a reordered file still imports, and the error
/// report (the same columns plus Row, Status and Message) can be corrected and uploaded again.
/// </summary>
public sealed class ContainerChargeImportParser
{
    /// <summary>A charge file is a few hundred rows: far below this.</summary>
    public const long MaxFileBytes = 5 * 1024 * 1024;

    /// <summary>The most data rows one file may carry, like the movement import's container numbers.</summary>
    public const int MaxDataRows = 500;

    /// <summary>The template's data sheet. Read first when present; otherwise the first sheet.</summary>
    public const string DataSheetName = "Charges";

    public const string TemplateMismatchMessage =
        "The file does not match the charges import template. Download the template and try again.";

    internal const string ColumnContainer = "Container";
    internal const string ColumnChargeType = "Charge Type";
    internal const string ColumnAmount = "Amount";
    internal const string ColumnCurrency = "Currency";
    internal const string ColumnChargeDate = "Charge Date";
    internal const string ColumnExchangeRate = "Exchange Rate";
    internal const string ColumnProvider = "Provider";
    internal const string ColumnProviderInvoiceNo = "Provider Invoice No.";
    internal const string ColumnAllocation = "Allocation";
    internal const string ColumnNotes = "Notes";

    /// <summary>The headings in the template's order. The parser matches the text, never the position.</summary>
    internal static readonly string[] TemplateHeaders =
    [
        ColumnContainer, ColumnChargeType, ColumnAmount, ColumnCurrency, ColumnChargeDate, ColumnExchangeRate,
        ColumnProvider, ColumnProviderInvoiceNo, ColumnAllocation, ColumnNotes,
    ];

    /// <summary>
    /// The headings and the aliases people type, lower case without spaces (see <see cref="Normalize"/>).
    /// "Ref" alone is left out on purpose: it would be the container's ref to one person and the invoice's to another.
    /// </summary>
    private static readonly Dictionary<string, string> HeaderAliases = new(StringComparer.Ordinal)
    {
        ["container"] = ColumnContainer,
        ["containerno."] = ColumnContainer,
        ["containerno"] = ColumnContainer,
        ["containernumber"] = ColumnContainer,
        ["containerref"] = ColumnContainer,
        ["containerreference"] = ColumnContainer,
        ["container/ref"] = ColumnContainer,
        ["chargetype"] = ColumnChargeType,
        ["chargetypecode"] = ColumnChargeType,
        ["chargecode"] = ColumnChargeType,
        ["charge"] = ColumnChargeType,
        ["amount"] = ColumnAmount,
        ["totalamount"] = ColumnAmount,
        ["currency"] = ColumnCurrency,
        ["currencycode"] = ColumnCurrency,
        ["chargedate"] = ColumnChargeDate,
        ["date"] = ColumnChargeDate,
        ["exchangerate"] = ColumnExchangeRate,
        ["rate"] = ColumnExchangeRate,
        ["provider"] = ColumnProvider,
        ["providercode"] = ColumnProvider,
        ["supplier"] = ColumnProvider,
        ["providerinvoiceno."] = ColumnProviderInvoiceNo,
        ["providerinvoiceno"] = ColumnProviderInvoiceNo,
        ["providerinvoicenumber"] = ColumnProviderInvoiceNo,
        ["providerinvoice"] = ColumnProviderInvoiceNo,
        ["invoiceno."] = ColumnProviderInvoiceNo,
        ["invoiceno"] = ColumnProviderInvoiceNo,
        ["invoicenumber"] = ColumnProviderInvoiceNo,
        ["reference"] = ColumnProviderInvoiceNo,
        ["allocation"] = ColumnAllocation,
        ["allocationmethod"] = ColumnAllocation,
        ["method"] = ColumnAllocation,
        ["notes"] = ColumnNotes,
        ["note"] = ColumnNotes,
    };

    /// <summary>The written dates accepted in a text cell: the app's own dd/MM/yyyy first (never the US order).</summary>
    private static readonly string[] DateFormats =
    [
        "dd/MM/yyyy", "d/M/yyyy", "dd/MM/yy", "d/M/yy", "yyyy-MM-dd", "dd-MM-yyyy", "d-M-yyyy", "dd.MM.yyyy", "d.M.yyyy",
        "d MMM yyyy", "dd MMM yyyy", "d MMMM yyyy", "dd-MMM-yyyy", "d-MMM-yyyy", "yyyy/MM/dd",
    ];

    /// <summary>
    /// A sign, digits — grouped by commas in threes after a first group of one to three that does not start
    /// with 0 (so "0,925" is not 925), or not grouped at all — then a point and the decimals.
    /// </summary>
    private static readonly Regex PlainNumber = new(
        @"^[+-]?(?:[1-9][0-9]{0,2}(?:,[0-9]{3})+|[0-9]+|(?=\.[0-9]))(?:\.[0-9]+)?$",
        RegexOptions.CultureInvariant);

    /// <exception cref="ContainerChargeImportFileException">The file is not a readable charge import file.</exception>
    public IReadOnlyList<ContainerChargeImportRow> Parse(Stream stream)
    {
        XLWorkbook workbook;
        try
        {
            workbook = new XLWorkbook(stream);
        }
        catch (Exception ex) when (ex is not ContainerChargeImportFileException)
        {
            // A .csv renamed, a corrupt upload, an .xls: the person is told about their file, the cause is kept for the log.
            throw new ContainerChargeImportFileException(
                "The file could not be opened as an Excel workbook (.xlsx). " + TemplateMismatchMessage, ex);
        }

        using (workbook)
        {
            var sheet = workbook.Worksheets.FirstOrDefault(s => string.Equals(s.Name.Trim(), DataSheetName, StringComparison.OrdinalIgnoreCase))
                ?? workbook.Worksheets.FirstOrDefault()
                ?? throw new ContainerChargeImportFileException("The workbook has no worksheets.");

            var (headerRow, columns) = FindHeader(sheet);

            if (!columns.ContainsKey(ColumnChargeType) || !columns.ContainsKey(ColumnAmount))
            {
                throw new ContainerChargeImportFileException(TemplateMismatchMessage);
            }

            return ReadRows(sheet, headerRow, columns);
        }
    }

    /// <summary>The first row holding a "Container" heading, among the first 25: files arrive with a title above the table.</summary>
    private static (int HeaderRow, Dictionary<string, int> Columns) FindHeader(IXLWorksheet sheet)
    {
        var used = sheet.RangeUsed() ?? throw new ContainerChargeImportFileException("The worksheet is empty.");

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

            if (columns.ContainsKey(ColumnContainer))
            {
                return (rowNumber, columns);
            }
        }

        throw new ContainerChargeImportFileException(TemplateMismatchMessage);
    }

    private static IReadOnlyList<ContainerChargeImportRow> ReadRows(IXLWorksheet sheet, int headerRow, Dictionary<string, int> columns)
    {
        var lastRow = sheet.RangeUsed()!.RangeAddress.LastAddress.RowNumber;
        var rows = new List<ContainerChargeImportRow>();

        for (var rowNumber = headerRow + 1; rowNumber <= lastRow; rowNumber++)
        {
            // A blank row is not a row: files carry them between groups and at the end.
            if (columns.Values.All(c => IsBlank(sheet.Cell(rowNumber, c))))
            {
                continue;
            }

            if (rows.Count >= MaxDataRows)
            {
                throw new ContainerChargeImportFileException(
                    $"The file has more than {MaxDataRows} rows. Split it and import the parts separately.");
            }

            var (amount, rawAmount) = ReadNumber(Cell(sheet, rowNumber, columns, ColumnAmount));
            var (rate, rawRate) = ReadNumber(Cell(sheet, rowNumber, columns, ColumnExchangeRate));
            var (date, rawDate) = ReadDate(Cell(sheet, rowNumber, columns, ColumnChargeDate));

            rows.Add(new ContainerChargeImportRow
            {
                RowNumber = rowNumber,
                Container = Text(sheet, rowNumber, columns, ColumnContainer),
                ChargeType = Text(sheet, rowNumber, columns, ColumnChargeType),
                Amount = amount,
                RawAmount = rawAmount,
                Currency = Text(sheet, rowNumber, columns, ColumnCurrency),
                ChargeDate = date,
                RawChargeDate = rawDate,
                ExchangeRate = rate,
                RawExchangeRate = rawRate,
                Provider = Text(sheet, rowNumber, columns, ColumnProvider),
                ProviderInvoiceNo = Text(sheet, rowNumber, columns, ColumnProviderInvoiceNo),
                Allocation = Text(sheet, rowNumber, columns, ColumnAllocation),
                Notes = Text(sheet, rowNumber, columns, ColumnNotes),
            });
        }

        return rows;
    }

    private static bool IsBlank(IXLCell cell) => cell.IsEmpty() || cell.GetString().Trim().Length == 0;

    private static IXLCell? Cell(IXLWorksheet sheet, int rowNumber, Dictionary<string, int> columns, string name)
        => columns.TryGetValue(name, out var columnNumber) ? sheet.Cell(rowNumber, columnNumber) : null;

    private static string? Text(IXLWorksheet sheet, int rowNumber, Dictionary<string, int> columns, string name)
    {
        var value = Cell(sheet, rowNumber, columns, name)?.GetString().Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }

    /// <summary>
    /// A number from a numeric cell, or from text written the one way that cannot be misread: a point for the
    /// decimals and, if any, commas grouping the thousands (2100.50, 2,100.50). An empty cell is "not given",
    /// not a failure.
    ///
    /// A COMMA IS ONLY EVER A THOUSANDS SEPARATOR, AND ONLY WHERE IT GROUPS THREE DIGITS. decimal.TryParse
    /// with NumberStyles.Number does not check the groups, so a decimal comma (2100,50 typed or pasted the
    /// French way) would read as 210050 and pass as a valid charge a hundred times too big. Such text, and any
    /// other text that is not plainly a number, is passed on as typed so the row says it is not a number.
    /// The server's culture is never used: the same file reads the same on every machine.
    /// </summary>
    private static (decimal? Value, string? Raw) ReadNumber(IXLCell? cell)
    {
        if (cell is null || cell.IsEmpty())
        {
            return (null, null);
        }

        if (cell.DataType == XLDataType.Number)
        {
            var number = cell.GetDouble();
            return double.IsFinite(number) && Math.Abs(number) < 1e17
                ? ((decimal)number, null)
                : (null, cell.GetString().Trim());
        }

        var text = cell.GetString().Trim();
        if (text.Length == 0)
        {
            return (null, null);
        }

        return PlainNumber.IsMatch(text)
               && decimal.TryParse(text.Replace(",", string.Empty, StringComparison.Ordinal),
                   NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var parsed)
            ? (parsed, null)
            : (null, text);
    }

    /// <summary>
    /// A date from a date cell, from a number Excel stores for a date typed in a cell formatted as a number,
    /// or from text in one of <see cref="DateFormats"/>. An empty cell is "not given" (today, in the service).
    /// </summary>
    private static (DateOnly? Value, string? Raw) ReadDate(IXLCell? cell)
    {
        if (cell is null || cell.IsEmpty())
        {
            return (null, null);
        }

        switch (cell.DataType)
        {
            case XLDataType.DateTime:
                return (DateOnly.FromDateTime(cell.GetDateTime()), null);

            // Days since 1900: 36526 is 1 January 2000, 73050 is 31 December 2099. Anything else is not a date.
            case XLDataType.Number when cell.GetDouble() is >= 36526 and < 73051:
                return (DateOnly.FromDateTime(DateTime.FromOADate(Math.Floor(cell.GetDouble()))), null);
        }

        var text = cell.GetString().Trim();
        if (text.Length == 0)
        {
            return (null, null);
        }

        return DateOnly.TryParseExact(text, DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var parsed)
            ? (parsed, null)
            : (null, text);
    }

    /// <summary>Lower-cased with every space removed, so "Charge Date" and "chargedate" are one heading.</summary>
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
