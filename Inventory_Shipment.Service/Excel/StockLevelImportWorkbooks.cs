using System.Globalization;
using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;

namespace Inventory_Shipment.Service.Excel;

/// <summary>
/// The three workbooks of stock levels per warehouse (script 91): the import template, the report of the rows that did
/// not come through cleanly, and the export of Inventory › Stock Levels.
///
/// WRITTEN BY THE CODE THAT READS THEM: their headings are <see cref="StockLevelImportParser.TemplateHeaders"/>, so a file
/// filled from the template, an error report corrected in Excel and an export edited by hand all import as they are.
/// The export puts the five import columns first and the information after them, grey and italic, each heading saying
/// "Information: the import ignores this column": the round trip is the export, edited, imported back.
/// </summary>
public static class StockLevelImportWorkbooks
{
    public const string TemplateFileName = "Import_Stock_Levels_Template.xlsx";
    public const string ErrorReportFileName = "Import_Stock_Levels_Errors.xlsx";
    public const string ExportFileName = "Stock_Levels.xlsx";
    public const string ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private const string QuantityFormat = "#,##0";
    private const string InformationComment = "Information: the import ignores this column";

    private static readonly XLColor HeaderFill = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
    private static readonly XLColor InformationColour = XLColor.FromArgb(0x6B, 0x72, 0x80);
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    /// <summary>The template rows the Remove drop-down covers: the parser's row limit and the header.</summary>
    private const int ListRows = StockLevelImportParser.MaxRows + 1;

    /* ── the template ─────────────────────────────────────────────────────────────────────────── */

    /// <summary>Sheets Levels (the five headings, bold, frozen, a Yes drop-down on Remove), Instructions and Example.</summary>
    public static byte[] GenerateTemplate()
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(StockLevelImportParser.DataSheetName);
        WriteHeaders(sheet, StockLevelImportParser.TemplateHeaders);
        FormatImportColumns(sheet, ListRows);
        AddRemoveDropDown(sheet, ListRows);
        sheet.SheetView.FreezeRows(1);
        SizeImportColumns(sheet);

        AddInstructions(workbook);
        AddExample(workbook);

        return ToBytes(workbook);
    }

    /* ── the error report ─────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The Warning and Error rows as the file had them, with Row first and Status and Message last: corrected in Excel and
    /// uploaded again (Row, Status and Message are not import headings, so they are ignored).
    /// </summary>
    public static byte[] GenerateErrorReport(IReadOnlyList<StockLevelImportRow> rows)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(StockLevelImportParser.DataSheetName);
        string[] headers = ["Row", .. StockLevelImportParser.TemplateHeaders, "Status", "Message"];
        WriteHeaders(sheet, headers);

        var problems = rows
            .Where(r => string.Equals(r.Status, StockLevelImportStatus.Error, StringComparison.Ordinal)
                        || string.Equals(r.Status, StockLevelImportStatus.Warning, StringComparison.Ordinal))
            .OrderBy(r => r.RowNumber)
            .ToList();

        var rowNumber = 2;
        foreach (var row in problems)
        {
            sheet.Cell(rowNumber, 1).Value = row.RowNumber;
            // WHAT WAS TYPED, not what it resolved to: on a row that failed because a code is unknown nothing resolved.
            SetText(sheet.Cell(rowNumber, 2), row.ItemInput);
            SetText(sheet.Cell(rowNumber, 3), row.WarehouseInput);
            SetQuantityOrText(sheet.Cell(rowNumber, 4), row.MinQuantityBase, row.RawMin);
            SetQuantityOrText(sheet.Cell(rowNumber, 5), row.MaxQuantityBase, row.RawMax);
            SetText(sheet.Cell(rowNumber, 6), row.Remove ? "Yes" : row.RawRemove);
            sheet.Cell(rowNumber, 7).Value = row.Status;
            SetText(sheet.Cell(rowNumber, 8), row.Message);

            var colour = string.Equals(row.Status, StockLevelImportStatus.Error, StringComparison.Ordinal)
                ? XLColor.FromArgb(0xC0, 0x39, 0x2B)
                : XLColor.FromArgb(0xD3, 0x7A, 0x06);

            // Only the status and the message carry the colour: the values on the left are what gets corrected.
            sheet.Range(rowNumber, 7, rowNumber, 8).Style.Font.FontColor = colour;
            sheet.Cell(rowNumber, 7).Style.Font.Bold = true;
            rowNumber++;
        }

        sheet.Range(2, 4, Math.Max(rowNumber, 2), 5).Style.NumberFormat.Format = QuantityFormat;
        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        sheet.Column(2).Width = Math.Max(sheet.Column(2).Width, 22);
        sheet.Column(3).Width = Math.Max(sheet.Column(3).Width, 16);
        sheet.Column(8).Width = 80;
        sheet.Column(8).Style.Alignment.WrapText = true;

        return ToBytes(workbook);
    }

    /* ── the export ───────────────────────────────────────────────────────────────────────────── */

    private static readonly string[] InformationHeaders =
        ["Item Name", "Branch", "On hand", "On the way in", "To come in", "To go out", "Projected", "Status", "Updated"];

    /// <summary>
    /// Sheet Levels: the five import columns (the item's code, the warehouse's code, Min, Max, Remove empty), then the
    /// information columns, grey italic; sheet Instructions. A row without a level (status "Without a level") exports with
    /// Min and Max empty, which the import reads as "Nothing to change".
    /// </summary>
    public static byte[] BuildExport(IReadOnlyList<StockLevelRowDto> rows)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(StockLevelImportParser.DataSheetName);
        string[] headers = [.. StockLevelImportParser.TemplateHeaders, .. InformationHeaders];
        WriteHeaders(sheet, headers);

        var importColumns = StockLevelImportParser.TemplateHeaders.Length;
        for (var column = importColumns + 1; column <= headers.Length; column++)
        {
            var heading = sheet.Cell(1, column);
            heading.Style.Font.FontColor = InformationColour;
            heading.Style.Font.Italic = true;
            heading.CreateComment().AddText(InformationComment);
        }

        var rowNumber = 2;
        foreach (var row in rows)
        {
            SetText(sheet.Cell(rowNumber, 1), row.ItemCode);
            SetText(sheet.Cell(rowNumber, 2), row.WarehouseCode);
            if (row.MinQuantityBase is { } min)
            {
                sheet.Cell(rowNumber, 3).Value = min;
            }

            if (row.MaxQuantityBase is { } max)
            {
                sheet.Cell(rowNumber, 4).Value = max;
            }

            // Remove (column 5) stays empty: typing Yes there removes the level on the way back.
            SetText(sheet.Cell(rowNumber, 6), row.ItemName);
            SetText(sheet.Cell(rowNumber, 7), row.BranchCode);
            sheet.Cell(rowNumber, 8).Value = row.OnHandBase;
            sheet.Cell(rowNumber, 9).Value = row.InOnTheWayBase;
            sheet.Cell(rowNumber, 10).Value = row.InToDispatchBase;
            sheet.Cell(rowNumber, 11).Value = row.OutToDispatchBase;
            sheet.Cell(rowNumber, 12).Value = row.ProjectedBase;
            SetText(sheet.Cell(rowNumber, 13), StockLevelStatuses.Label(row.Status));
            SetText(sheet.Cell(rowNumber, 14), Updated(row));
            rowNumber++;
        }

        var lastRow = Math.Max(rowNumber - 1, 2);
        FormatImportColumns(sheet, lastRow);
        AddRemoveDropDown(sheet, Math.Max(lastRow, 2));
        sheet.Range(2, 8, lastRow, 12).Style.NumberFormat.Format = QuantityFormat;
        var information = sheet.Range(2, importColumns + 1, lastRow, headers.Length);
        information.Style.Font.FontColor = InformationColour;
        information.Style.Font.Italic = true;

        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        SizeImportColumns(sheet);
        sheet.Column(6).Width = Math.Min(Math.Max(sheet.Column(6).Width, 24), 60);

        AddExportInstructions(workbook);
        return ToBytes(workbook);
    }

    /// <summary>"24/10/2026 by Manager One" (the date the level was last changed, UTC), as the item card reads it.</summary>
    private static string? Updated(StockLevelRowDto row)
    {
        if (row.UpdatedAtUtc is not { } at)
        {
            return null;
        }

        var date = at.ToString("dd/MM/yyyy", Invariant);
        return string.IsNullOrWhiteSpace(row.UpdatedByName) ? date : $"{date} by {row.UpdatedByName}";
    }

    /* ── the sheets ───────────────────────────────────────────────────────────────────────────── */

    private static void AddInstructions(XLWorkbook workbook)
    {
        var sheet = workbook.AddWorksheet("Instructions");
        WriteHeaders(sheet, ["Column", "Required", "What it does"]);

        (string Column, string Required, string What)[] columns =
        [
            (StockLevelImportParser.ColumnItem, "Yes", "The item's code, or the barcode of one of its units."),
            (StockLevelImportParser.ColumnWarehouse, "Yes",
                "The warehouse's code (or its name when no other warehouse has it): a warehouse at the bottom of the tree, not an On the way warehouse."),
            (StockLevelImportParser.ColumnMin, "Yes, unless Remove",
                "The least the warehouse should hold, in pcs (the item's base unit): a whole number, 0 or more. Fill to Max acts when the warehouse's projected stock is below it."),
            (StockLevelImportParser.ColumnMax, "No",
                "The most it should hold, in pcs, not less than Min. Empty: no maximum (Fill to Max fills up to Min)."),
            (StockLevelImportParser.ColumnRemove, "No",
                "Yes removes the warehouse's level for the item; Min and Max are then ignored."),
        ];

        var rowNumber = 2;
        foreach (var (column, required, what) in columns)
        {
            sheet.Cell(rowNumber, 1).Value = column;
            sheet.Cell(rowNumber, 2).Value = required;
            sheet.Cell(rowNumber, 3).Value = what;
            rowNumber++;
        }

        string[] notes =
        [
            "A row with Min and Max empty changes nothing.",
            "Other columns are ignored: an export of Inventory › Stock Levels can be edited and imported back.",
            $"Every row is checked first; the rows without an error are then saved together. At most {StockLevelImportParser.MaxRows.ToString("N0", Invariant)} rows, 5 MB.",
        ];
        WriteNotes(sheet, rowNumber + 1, notes);

        sheet.Column(1).Width = 22;
        sheet.Column(2).Width = 20;
        sheet.Column(3).Width = 110;
        sheet.Column(3).Style.Alignment.WrapText = true;
        sheet.SheetView.FreezeRows(1);
    }

    private static void AddExample(XLWorkbook workbook)
    {
        var sheet = workbook.AddWorksheet("Example");
        WriteHeaders(sheet, StockLevelImportParser.TemplateHeaders);
        sheet.Cell(2, 1).Value = "TVS-APACHE-160";
        sheet.Cell(2, 2).Value = "LUB-01";
        sheet.Cell(2, 3).Value = 20;
        sheet.Cell(2, 4).Value = 60;
        sheet.Cell(3, 1).Value = "TVS-XL100";
        sheet.Cell(3, 2).Value = "LKS-01";
        sheet.Cell(3, 5).Value = "Yes";
        sheet.Range(2, 1, 3, 5).Style.Font.FontColor = InformationColour;
        sheet.SheetView.FreezeRows(1);
        SizeImportColumns(sheet);
    }

    private static void AddExportInstructions(XLWorkbook workbook)
    {
        var sheet = workbook.AddWorksheet("Instructions");
        WriteHeaders(sheet, ["How to use this file"]);
        string[] notes =
        [
            "The first five columns are the import's: Item Code / Barcode, Warehouse, Min (pcs), Max (pcs) and Remove.",
            "Change Min or Max, or put Yes in Remove, then import the file with Import from Excel… on Inventory › Stock Levels.",
            "The grey columns are information: the import ignores them. Rows left as they are come back as \"No change\".",
            "Min and Max are in pcs (the item's base unit). Max empty: no maximum (Fill to Max fills up to Min).",
            "Projected = On hand + On the way in + To come in − To go out (released transfer orders only).",
        ];
        WriteNotes(sheet, 2, notes);
        sheet.Column(1).Width = 120;
    }

    /* ── helpers ──────────────────────────────────────────────────────────────────────────────── */

    private static void WriteHeaders(IXLWorksheet sheet, IReadOnlyList<string> headers)
    {
        for (var index = 0; index < headers.Count; index++)
        {
            sheet.Cell(1, index + 1).Value = headers[index];
        }

        var header = sheet.Range(1, 1, 1, headers.Count);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = HeaderFill;
        header.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
    }

    private static void WriteNotes(IXLWorksheet sheet, int firstRow, IReadOnlyList<string> notes)
    {
        var rowNumber = firstRow;
        foreach (var note in notes)
        {
            sheet.Cell(rowNumber, 1).Value = note;
            sheet.Cell(rowNumber, 1).Style.Font.Italic = true;
            sheet.Cell(rowNumber, 1).Style.Alignment.WrapText = true;
            rowNumber++;
        }
    }

    /// <summary>Codes as text (a code such as 000123 keeps its zeros), Min / Max as whole numbers.</summary>
    private static void FormatImportColumns(IXLWorksheet sheet, int lastRow)
    {
        sheet.Range(2, 1, lastRow, 2).Style.NumberFormat.Format = "@";
        sheet.Range(2, 3, lastRow, 4).Style.NumberFormat.Format = QuantityFormat;
    }

    private static void AddRemoveDropDown(IXLWorksheet sheet, int lastRow)
    {
        var remove = sheet.Range(2, 5, lastRow, 5).CreateDataValidation();
        remove.List("\"Yes\"", true);
        remove.IgnoreBlanks = true;
        remove.ShowErrorMessage = true;
        remove.ErrorTitle = StockLevelImportParser.ColumnRemove;
        remove.ErrorMessage = "Yes removes the level; leave it empty otherwise.";
    }

    private static void SizeImportColumns(IXLWorksheet sheet)
    {
        sheet.Column(1).Width = Math.Max(sheet.Column(1).Width, 22);
        sheet.Column(2).Width = Math.Max(sheet.Column(2).Width, 16);
        sheet.Column(3).Width = Math.Max(sheet.Column(3).Width, 11);
        sheet.Column(4).Width = Math.Max(sheet.Column(4).Width, 11);
        sheet.Column(5).Width = Math.Max(sheet.Column(5).Width, 10);
    }

    private static void SetText(IXLCell cell, string? value)
    {
        if (!string.IsNullOrEmpty(value))
        {
            cell.Value = value;
        }
    }

    /// <summary>A number stays a number (the report imports again); a value that did not read is written as typed.</summary>
    private static void SetQuantityOrText(IXLCell cell, int? value, string? raw)
    {
        if (value is { } number)
        {
            cell.Value = number;
        }
        else if (!string.IsNullOrEmpty(raw))
        {
            cell.Value = raw;
        }
    }

    private static byte[] ToBytes(XLWorkbook workbook)
    {
        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
