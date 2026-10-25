using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;

namespace Inventory_Shipment.Service.Excel;

/// <summary>
/// The two workbooks of a transfer order (script 90): the template its lines are imported from, and the export of one
/// order.
///
/// THE TEMPLATE IS READ BY <see cref="InvoiceImportParser"/>, the parser of every document import, so its headings are
/// ones that parser matches ("Item Code / Barcode", "Unit", "Quantity", "Notes") and nothing else: a transfer takes its
/// warehouses from the order and has no cost, so the template has neither a Warehouse nor a Unit Price column (a file
/// that carries one is refused row by row: TransferOrderService.ValidateImportAsync). The first sheet is the one read.
///
/// THE EXPORT SHOWS VALUES ONLY TO WHO MAY SEE THEM: the service passes <c>withValues</c> from the reader's permission,
/// and without it the value columns are left out, not filled with zeros.
/// </summary>
public static class TransferOrderWorkbooks
{
    public const string ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    public const string TemplateFileName = "Transfer_Order_Lines_Template.xlsx";

    /// <summary>The headings of the "Lines" sheet, in order.</summary>
    private static readonly string[] TemplateHeaders = ["Item Code / Barcode", "Unit", "Quantity", "Notes"];

    private static readonly XLColor HeaderFill = XLColor.FromArgb(0xE8, 0xEE, 0xF7);

    /// <summary>The blank template: sheet "Lines" with the four headings, sheet "Instructions" saying what each means.</summary>
    public static byte[] GenerateTemplate()
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Lines");
        for (var index = 0; index < TemplateHeaders.Length; index++)
        {
            sheet.Cell(1, index + 1).Value = TemplateHeaders[index];
        }

        StyleHeader(sheet.Range(1, 1, 1, TemplateHeaders.Length));
        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        sheet.Column(4).Width = 40;

        var instructions = workbook.AddWorksheet("Instructions");
        instructions.Cell(1, 1).Value = "Transfer order lines - how to fill the Lines sheet";
        instructions.Cell(1, 1).Style.Font.Bold = true;
        instructions.Cell(1, 1).Style.Font.FontSize = 13;

        (string Column, string Required, string Behaviour)[] rows =
        [
            ("Item Code / Barcode", "Required",
                "The item's code, or the barcode of one of its units. A barcode also settles which unit the row means (a box barcode: the box)."),
            ("Unit", "Optional",
                "The unit type name (PC, Box) or the unit's SKU. Blank unit = the item's base unit."),
            ("Quantity", "Required",
                "Quantity: a whole number in the unit, greater than zero."),
            ("Notes", "Optional",
                "Free text kept on the line."),
        ];

        instructions.Cell(3, 1).Value = "Column";
        instructions.Cell(3, 2).Value = "Required";
        instructions.Cell(3, 3).Value = "What it means";
        StyleHeader(instructions.Range(3, 1, 3, 3));

        var row = 4;
        foreach (var (column, required, behaviour) in rows)
        {
            instructions.Cell(row, 1).Value = column;
            instructions.Cell(row, 2).Value = required;
            instructions.Cell(row, 3).Value = behaviour;
            row++;
        }

        row++;
        instructions.Cell(row, 1).Value = "No warehouse or cost: they come from the order. Every line leaves the order's From and goes to its To, "
                                          + "and a transfer moves no cost. A file with a Warehouse or a Unit Price column has those rows refused.";
        instructions.Cell(row + 1, 1).Value = "Only the first sheet (Lines) is read. Nothing is saved by the import: the lines are added to the draft, "
                                              + "which is saved with Save.";

        instructions.Column(1).Width = 24;
        instructions.Column(2).Width = 12;
        instructions.Column(3).Width = 100;
        instructions.Range(4, 3, row - 2, 3).Style.Alignment.WrapText = true;

        return ToBytes(workbook);
    }

    /// <summary>"TRO-BR-003-000012.xlsx" - without doubling the prefix; a draft without a number is "TRO-DRAFT-{id}.xlsx".</summary>
    public static string ExportFileName(TransferOrderDto order)
    {
        if (string.IsNullOrWhiteSpace(order.DocumentNumber))
        {
            return $"TRO-DRAFT-{order.Id}.xlsx";
        }

        var number = order.DocumentNumber.Trim();
        return (number.StartsWith("TRO-", StringComparison.OrdinalIgnoreCase) ? number : "TRO-" + number) + ".xlsx";
    }

    /// <summary>Sheets "Order", "Lines" and "Dispatches and receipts" (2.5.6); the values only <paramref name="withValues"/>.</summary>
    public static byte[] BuildExport(TransferOrderDto order, bool withValues)
    {
        using var workbook = new XLWorkbook();
        WriteOrder(workbook.AddWorksheet("Order"), order, withValues);
        WriteLines(workbook.AddWorksheet("Lines"), order);
        WritePostings(workbook.AddWorksheet("Dispatches and receipts"), order, withValues);
        return ToBytes(workbook);
    }

    private static void WriteOrder(IXLWorksheet sheet, TransferOrderDto order, bool withValues)
    {
        sheet.Cell(1, 1).Value = $"Transfer Order {order.DocumentNumber ?? "(draft)"}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var header = new List<(string Label, XLCellValue Value)>
        {
            ("Transfer Order No.", order.DocumentNumber ?? "DRAFT"),
            ("Status", ShownStatus(order.DisplayStatus) + (order.IsLate ? " (late)" : string.Empty)),
            ("Order date", order.DocumentDate.ToString("dd/MM/yyyy")),
            ("From", Warehouse(order.From)),
            ("To", Warehouse(order.To)),
            ("Expected arrival", order.ExpectedArrival?.ToString("dd/MM/yyyy") ?? string.Empty),
            ("Reference No.", order.ReferenceNo ?? string.Empty),
            ("Notes", order.Notes ?? string.Empty),
        };

        if (order.ReturnOf is { } returnOf)
        {
            header.Add(("Return of", returnOf.DocumentNumber ?? $"#{returnOf.Id}"));
        }

        if (order.Approval.ApprovedAtUtc is { } approvedAt)
        {
            header.Add(("Approved", $"{approvedAt:dd/MM/yyyy HH:mm} UTC {order.Approval.ApprovedByName}".Trim()));
        }

        if (order.Released is { } released)
        {
            header.Add(("Released", $"{released.AtUtc:dd/MM/yyyy HH:mm} UTC {released.ByName}".Trim()));
        }

        if (order.NotSent is { } notSent)
        {
            header.Add(("Nothing more will be sent", $"{notSent.AtUtc:dd/MM/yyyy} {notSent.ByName}: {notSent.Reason}".Trim()));
        }

        if (order.Cancelled is { } cancelled)
        {
            header.Add(("Cancelled", $"{cancelled.AtUtc:dd/MM/yyyy} {cancelled.ByName}: {cancelled.Reason}".Trim()));
        }

        header.Add(("Ordered (pcs)", order.Totals.OrderedBase));
        header.Add(("Dispatched (pcs)", order.Totals.DispatchedBase));
        header.Add(("Received (pcs)", order.Totals.ReceivedBase));
        header.Add(("On the way (pcs)", order.Totals.OnTheWayBase));
        header.Add(("Not sent (pcs)", order.Totals.NotSentBase));
        header.Add(("Lost (pcs)", order.Totals.LostBase));
        header.Add(("To dispatch (pcs)", order.Totals.ToDispatchBase));
        if (withValues && order.OnTheWayValueBase is { } value)
        {
            header.Add(("On the way, value (base)", value));
        }

        var row = 3;
        foreach (var (label, cellValue) in header)
        {
            sheet.Cell(row, 1).Value = label;
            sheet.Cell(row, 1).Style.Font.Bold = true;
            sheet.Cell(row, 2).Value = cellValue;
            if (cellValue.IsNumber)
            {
                sheet.Cell(row, 2).Style.NumberFormat.Format = label.Contains("value", StringComparison.OrdinalIgnoreCase) ? "#,##0.00" : "#,##0";
                sheet.Cell(row, 2).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
            }

            row++;
        }

        sheet.Column(1).Width = 26;
        sheet.Column(2).Width = 60;
    }

    private static void WriteLines(IXLWorksheet sheet, TransferOrderDto order)
    {
        string[] columns =
        [
            "#", "Item Code", "Item Name", "Unit", "Ordered", "Ordered (pcs)", "Dispatched (pcs)", "Received (pcs)", "Lost (pcs)",
            "Not sent (pcs)", "To dispatch (pcs)", "On the way (pcs)", "Notes",
        ];
        WriteHeader(sheet, 1, columns);

        var row = 1;
        foreach (var line in order.Lines)
        {
            row++;
            sheet.Cell(row, 1).Value = line.LineNumber;
            sheet.Cell(row, 2).Value = line.ItemCode;
            sheet.Cell(row, 3).Value = line.ItemName;
            sheet.Cell(row, 4).Value = line.PackingFormula > 1 ? $"{line.UnitName} (x{line.PackingFormula})" : line.UnitName;
            sheet.Cell(row, 5).Value = line.Quantity;
            sheet.Cell(row, 6).Value = line.OrderedBase;
            sheet.Cell(row, 7).Value = line.DispatchedBase;
            sheet.Cell(row, 8).Value = line.ReceivedBase;
            sheet.Cell(row, 9).Value = line.LostBase;
            sheet.Cell(row, 10).Value = line.NotSentBase;
            sheet.Cell(row, 11).Value = line.ToDispatchBase;
            sheet.Cell(row, 12).Value = line.OnTheWayBase;
            sheet.Cell(row, 13).Value = line.Notes ?? string.Empty;
        }

        if (order.Lines.Count > 0)
        {
            sheet.Range(2, 5, row, 12).Style.NumberFormat.Format = "#,##0";
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(3).Width = 36;
        sheet.Column(13).Width = 30;
    }

    private static void WritePostings(IXLWorksheet sheet, TransferOrderDto order, bool withValues)
    {
        var columns = new List<string> { "Number", "Kind", "Date", "ETA", "Status", "Pcs", "Lost (pcs)", "Reference" };
        if (withValues)
        {
            columns.Add("Value (base)");
            columns.Add("Lost value (base)");
        }

        columns.Add("Posted by");
        columns.Add("Reversed");
        WriteHeader(sheet, 1, [.. columns]);

        var row = 1;
        foreach (var posting in order.Postings)
        {
            row++;
            var column = 1;
            sheet.Cell(row, column++).Value = posting.DocumentNumber;
            sheet.Cell(row, column++).Value = posting.Kind;
            sheet.Cell(row, column++).Value = posting.PostingDate.ToString("dd/MM/yyyy");
            sheet.Cell(row, column++).Value = posting.Eta?.ToString("dd/MM/yyyy") ?? string.Empty;
            sheet.Cell(row, column++).Value = posting.Status;
            sheet.Cell(row, column).Value = posting.TotalQuantityBase;
            sheet.Cell(row, column++).Style.NumberFormat.Format = "#,##0";
            sheet.Cell(row, column).Value = posting.TotalLostBase;
            sheet.Cell(row, column++).Style.NumberFormat.Format = "#,##0";
            sheet.Cell(row, column++).Value = posting.ReferenceNo ?? string.Empty;
            if (withValues)
            {
                sheet.Cell(row, column).Value = posting.ValueBase is { } value ? value : Blank.Value;
                sheet.Cell(row, column++).Style.NumberFormat.Format = "#,##0.00";
                sheet.Cell(row, column).Value = posting.LostValueBase is { } lost ? lost : Blank.Value;
                sheet.Cell(row, column++).Style.NumberFormat.Format = "#,##0.00";
            }

            sheet.Cell(row, column++).Value = posting.PostedByName ?? string.Empty;
            sheet.Cell(row, column).Value = posting.Reversed is { } reversed
                ? $"Reversed on {reversed.Date:dd/MM/yyyy} by {reversed.ByName}: {reversed.Reason}"
                : string.Empty;
        }

        sheet.Columns().AdjustToContents();
    }

    /// <summary>The words of the shown statuses (T7).</summary>
    private static string ShownStatus(string status) => status switch
    {
        "PendingApproval" => "Waiting for approval",
        "PartlyDispatched" => "Partly dispatched",
        "PartlyReceived" => "Partly received",
        _ => status,
    };

    private static string Warehouse(TransferWarehouseRefDto warehouse)
    {
        var name = string.Join(" - ", new[] { warehouse.Code, warehouse.Name }.Where(s => !string.IsNullOrWhiteSpace(s)));
        return string.IsNullOrWhiteSpace(warehouse.BranchCode) ? name : $"{name} ({warehouse.BranchCode})";
    }

    private static void WriteHeader(IXLWorksheet sheet, int row, string[] columns)
    {
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(row, i + 1).Value = columns[i];
        }

        StyleHeader(sheet.Range(row, 1, row, columns.Length));
    }

    private static void StyleHeader(IXLRange range)
    {
        range.Style.Font.Bold = true;
        range.Style.Fill.BackgroundColor = HeaderFill;
        range.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
    }

    private static byte[] ToBytes(XLWorkbook workbook)
    {
        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
