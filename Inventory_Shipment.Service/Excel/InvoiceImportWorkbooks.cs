using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Service.Excel;

/// <summary>
/// The two workbooks this feature hands OUT: the blank template, and the report of what went wrong.
///
/// ONE TEMPLATE FOR EVERY DOCUMENT TYPE. Inventory In, a sales invoice and a purchase order all
/// import the same columns; what differs is what the price column means (a cost or a selling price)
/// and which type the rows are for — so the template carries a "Document Type" column pre-filled
/// with the requesting page's code, and the instructions list every type. One shape to learn, one
/// parser to keep right.
///
/// THE TEMPLATE IS THE CONTRACT, AND IT IS WRITTEN BY THE CODE THAT READS IT. A template kept as a
/// checked-in file drifts from the parser the first time a column is renamed, and the failure is a
/// person following the official template and being told it is not the official template. Generating
/// it here means the headings can only be the ones <see cref="InvoiceImportParser"/> matches.
///
/// THE ERROR REPORT IS THE SAME FILE BACK, ANNOTATED, because the fix happens in Excel. Somebody
/// with forty bad rows out of six hundred needs the forty, with the reason beside each — not a
/// screen they have to read and copy from.
/// </summary>
public sealed class InvoiceImportWorkbooks
{
    public const string ErrorReportFileName = "Import_Errors.xlsx";
    public const string ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private const string DateFormat = "dd/MM/yyyy";

    /// <summary>"Import_INV_IN_Template.xlsx" — the type in the name, so a downloaded file says what it is for.</summary>
    public static string TemplateFileNameFor(string documentTypeCode) => $"Import_{documentTypeCode}_Template.xlsx";

    /// <summary>The headings, in the order the template lays them out. The parser matches on the text, not the order.</summary>
    private static readonly string[] TemplateHeaders =
        ["Document Type", "Item Code / Barcode", "Unit", "Warehouse", "Quantity", "Unit Price / Cost", "Discount %", "Expiry Date", "Notes"];

    /// <summary>
    /// Three rows showing the three shapes a line takes: everything defaulted, a unit and warehouse
    /// named, and a price with a discount and an expiry. The type code is filled in per request.
    ///
    /// EXAMPLES RATHER THAN AN EMPTY GRID. "Unit: blank means the family's unit" is a sentence people
    /// skip; a row with the column visibly empty and a working import behind it is not.
    /// </summary>
    private static object?[][] ExampleRows(string typeCode) =>
    [
        [typeCode, "OIL-001", null, null, 10, null, null, null, "Unit, warehouse and price left blank: the defaults are used."],
        [typeCode, "BAT-001", "Box", "WH-001", 5, null, 5, null, "A unit and a warehouse named explicitly — a second warehouse makes a second document."],
        [typeCode, "SPK-001", "PC", null, 24, 12.5, 10, new DateTime(2027, 12, 31), "A price / cost typed in. On a sales document it needs the price-override permission."],
    ];

    /// <summary>Column, whether it is required, and what happens when it is left blank.</summary>
    private static (string Column, string Required, string Behaviour)[] Instructions(DocumentTypeDto type, IReadOnlyList<DocumentTypeDto> types)
    {
        var typeList = string.Join(", ", types.OrderBy(t => t.Family).ThenBy(t => t.Code).Select(t => $"{t.Code} ({t.Name})"));

        return
        [
            ("Document Type", "Optional",
                $"The code or name of the document type the row is for. Blank means {type.Name} ({type.Code}), the page this template was downloaded from. "
                + $"A row for another type is rejected — one file makes one kind of document. Types: {typeList}."),
            ("Item Code / Barcode", "Required",
                "The item's code, or the barcode of one of its units. A barcode also settles which unit the row means."),
            ("Unit", "Optional",
                "The unit type name (PC, Box) or the unit's SKU. Blank uses the family's unit: the sales unit on a sales document, the purchase unit on a purchase document, the base unit on an inventory document."),
            ("Warehouse", "Optional",
                "The warehouse code or name; it must belong to the document's branch. Blank uses the header warehouse. ONE DOCUMENT IS CREATED PER WAREHOUSE found in the file."),
            ("Quantity", "Required",
                "A whole number of units, greater than zero."),
            ("Unit Price / Cost", "Optional",
                "On a sales document: the selling price. Blank uses the price list (the branch price first, then the All Branches price); a price typed here is only accepted from a user holding the price-override permission. "
                + "On Inventory In and purchase documents: the unit cost. Ignored on Inventory Out, which takes the moving average cost."),
            ("Discount %", "Optional",
                "Sales and purchase documents only. Blank is 0; it must be between 0 and the maximum the system allows. Both 5 and 5% are read as five percent."),
            ("Expiry Date", "Optional",
                "A date cell, or text as dd/MM/yyyy or yyyy-MM-dd. A date in the past is imported with a warning."),
            ("Notes", "Optional",
                "Free text kept on the line. Rows are only merged together when their notes match as well."),
        ];
    }

    /// <summary>The blank template for one type: headings, three examples with the type filled in, and the instructions.</summary>
    public byte[] GenerateTemplate(DocumentTypeDto type, IReadOnlyList<DocumentTypeDto> types)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Import");

        for (var index = 0; index < TemplateHeaders.Length; index++)
        {
            sheet.Cell(1, index + 1).Value = TemplateHeaders[index];
        }

        var header = sheet.Range(1, 1, 1, TemplateHeaders.Length);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        header.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var examples = ExampleRows(type.Code);
        for (var rowIndex = 0; rowIndex < examples.Length; rowIndex++)
        {
            var values = examples[rowIndex];
            for (var columnIndex = 0; columnIndex < values.Length; columnIndex++)
            {
                SetCell(sheet.Cell(rowIndex + 2, columnIndex + 1), values[columnIndex]);
            }
        }

        // Formatted rather than left to the reader's locale: an American Excel would otherwise show
        // 31/12/2027 as 12/31/2027, and the next person to type a row would copy that shape back in.
        sheet.Column(8).Style.DateFormat.Format = DateFormat;

        // Frozen so the headings stay visible on row 400, which is where a mistake gets made.
        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        sheet.Column(9).Width = 70;

        AddInstructions(workbook, type, types);

        return ToBytes(workbook);
    }

    /// <summary>
    /// The rows that did not come through cleanly, with the reason beside each.
    ///
    /// WARNINGS ARE IN IT AS WELL AS ERRORS, and they are different colours. A warning row IS
    /// imported, so the report is not "what to fix before retrying" but "what to look at" — and a
    /// person who has been told their manual prices were ignored will want the list of them even
    /// though nothing was rejected.
    /// </summary>
    public byte[] GenerateErrorReport(IReadOnlyList<InvoiceImportValidatedRow> rows)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Import Errors");

        string[] headers =
        [
            "Row", "Document Type", "Item Code / Barcode", "Unit", "Warehouse", "Quantity",
            "Unit Price / Cost", "Discount %", "Expiry Date", "Status", "Message"
        ];

        for (var index = 0; index < headers.Length; index++)
        {
            sheet.Cell(1, index + 1).Value = headers[index];
        }

        var header = sheet.Range(1, 1, 1, headers.Length);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        header.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var problems = rows
            .Where(r => !string.Equals(r.Status, InvoiceImportStatus.Valid, StringComparison.Ordinal))
            .OrderBy(r => r.RowNumber)
            .ToList();

        var rowNumber = 2;
        foreach (var row in problems)
        {
            sheet.Cell(rowNumber, 1).Value = row.RowNumber;
            SetCell(sheet.Cell(rowNumber, 2), row.RowDocumentTypeCode);
            // ItemRef, not ItemCode: on the row that failed BECAUSE the code is unknown there is no
            // ItemCode, and what the person needs to see is what they actually typed.
            SetCell(sheet.Cell(rowNumber, 3), row.ItemRef);
            SetCell(sheet.Cell(rowNumber, 4), row.UnitTypeName);
            SetCell(sheet.Cell(rowNumber, 5), row.WarehouseCode);
            SetCell(sheet.Cell(rowNumber, 6), row.Quantity);
            SetCell(sheet.Cell(rowNumber, 7), row.UnitPrice);
            SetCell(sheet.Cell(rowNumber, 8), row.DiscountPercent);
            SetCell(sheet.Cell(rowNumber, 9), row.ExpiryDate);
            sheet.Cell(rowNumber, 10).Value = row.Status;
            SetCell(sheet.Cell(rowNumber, 11), row.Message);

            var colour = row.Status switch
            {
                InvoiceImportStatus.Error => XLColor.FromArgb(0xC0, 0x39, 0x2B),
                InvoiceImportStatus.Warning => XLColor.FromArgb(0xD3, 0x7A, 0x06),
                _ => XLColor.FromArgb(0x6B, 0x72, 0x80),
            };

            // The status and the message carry the colour rather than the whole row: the values on
            // the left are what the person is about to correct, and they have to stay readable.
            sheet.Range(rowNumber, 10, rowNumber, 11).Style.Font.FontColor = colour;
            sheet.Cell(rowNumber, 10).Style.Font.Bold = true;

            rowNumber++;
        }

        sheet.Column(9).Style.DateFormat.Format = DateFormat;
        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        sheet.Column(11).Width = 80;
        sheet.Column(11).Style.Alignment.WrapText = true;

        return ToBytes(workbook);
    }

    private static void AddInstructions(XLWorkbook workbook, DocumentTypeDto type, IReadOnlyList<DocumentTypeDto> types)
    {
        var sheet = workbook.AddWorksheet("Instructions");

        sheet.Cell(1, 1).Value = "Column";
        sheet.Cell(1, 2).Value = "Required";
        sheet.Cell(1, 3).Value = "What happens";

        var header = sheet.Range(1, 1, 1, 3);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        header.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var rowNumber = 2;
        foreach (var (column, required, behaviour) in Instructions(type, types))
        {
            sheet.Cell(rowNumber, 1).Value = column;
            sheet.Cell(rowNumber, 2).Value = required;
            sheet.Cell(rowNumber, 3).Value = behaviour;
            rowNumber++;
        }

        rowNumber++;
        sheet.Cell(rowNumber, 1).Value = $"This template was downloaded for {type.Name} ({type.Code}). "
            + "One document is created per warehouse found in the file; rows with the Warehouse column blank go to the header warehouse.";
        sheet.Range(rowNumber, 1, rowNumber, 3).Merge().Style.Font.Italic = true;

        rowNumber++;
        sheet.Cell(rowNumber, 1).Value = "Rows that are identical in item, unit, warehouse, price, "
            + "discount, expiry date and notes are merged into one line and their quantities added up.";
        sheet.Range(rowNumber, 1, rowNumber, 3).Merge().Style.Font.Italic = true;

        rowNumber++;
        sheet.Cell(rowNumber, 1).Value = "Delete the example rows before importing. Blank rows are ignored.";
        sheet.Range(rowNumber, 1, rowNumber, 3).Merge().Style.Font.Italic = true;

        rowNumber += 2;
        sheet.Cell(rowNumber, 1).Value = "Document types";
        sheet.Cell(rowNumber, 1).Style.Font.Bold = true;
        foreach (var t in types.OrderBy(t => t.Family).ThenBy(t => t.Code))
        {
            rowNumber++;
            sheet.Cell(rowNumber, 1).Value = t.Code;
            sheet.Cell(rowNumber, 2).Value = t.Family;
            sheet.Cell(rowNumber, 3).Value = t.Name
                + (t.DefaultPricing == "PriceList" ? " — Unit Price / Cost is the selling price"
                    : t.DefaultPricing == "Cost" && t.StockDirection >= 0 ? " — Unit Price / Cost is the unit cost"
                    : t.DefaultPricing == "Cost" ? " — the moving average cost is applied; the price column is ignored"
                    : " — no pricing");
        }

        sheet.Column(1).Width = 22;
        sheet.Column(2).Width = 12;
        sheet.Column(3).Width = 110;
        sheet.Column(3).Style.Alignment.WrapText = true;
        sheet.SheetView.FreezeRows(1);
    }

    /// <summary>
    /// Writes a value with its own type, so a number stays a number.
    ///
    /// XLCellValue has no conversion from object, and going through ToString() would make every
    /// quantity text — which imports back as text, and would make the error report a file nobody can
    /// correct and re-upload.
    /// </summary>
    private static void SetCell(IXLCell cell, object? value)
    {
        switch (value)
        {
            case null:
                return;
            case string text:
                cell.Value = text;
                return;
            case int number:
                cell.Value = number;
                return;
            case decimal number:
                cell.Value = number;
                return;
            case double number:
                cell.Value = number;
                return;
            case DateTime date:
                cell.Value = date;
                cell.Style.DateFormat.Format = DateFormat;
                return;
            default:
                cell.Value = value.ToString();
                return;
        }
    }

    private static byte[] ToBytes(XLWorkbook workbook)
    {
        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
