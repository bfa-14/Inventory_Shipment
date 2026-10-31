using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Reports › Container Report (script 95): the purchasing team's tracking sheet, worked out by the system.
///
/// THE SERVER STRIPS, THE PAGE HIDES. Without View Container Charges every charge figure leaves the API null (the line's
/// FOB, its total and its cost per unit stay: a container's own page shows them with View Containers); without View
/// Supplier Payments the payment columns do. The export leaves the same columns out.
/// </summary>
public sealed class ContainerReportService : IContainerReportService
{
    private const string ForbiddenCode = "FORBIDDEN";

    private static readonly Dictionary<byte, string> StatusNames = new()
    {
        [1] = "Draft", [2] = "Confirmed", [3] = "In Transit", [4] = "At Port", [5] = "Cleared",
        [6] = "Offloaded", [7] = "Closed", [8] = "Cancelled",
    };

    private readonly IContainerReportRepository _reports;
    private readonly TimeProvider _clock;

    public ContainerReportService(IContainerReportRepository reports, TimeProvider clock)
    {
        _reports = reports;
        _clock = clock;
    }

    public async Task<Result<ContainerReportResult>> ReportAsync(
        ContainerReportQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ReportView))
        {
            return Result<ContainerReportResult>.Failure(
                ErrorType.Forbidden, $"This action needs the {Permissions.Containers.ReportView} permission.", ForbiddenCode);
        }

        if (query.OrderDateFrom is { } of && query.OrderDateTo is { } ot && of > ot)
        {
            return Result<ContainerReportResult>.Failure(
                ErrorType.Validation, "The order date from is after the order date to.", "VALIDATION");
        }

        if (query.OffloadedFrom is { } ff && query.OffloadedTo is { } ft && ff > ft)
        {
            return Result<ContainerReportResult>.Failure(
                ErrorType.Validation, "The offloaded from date is after the offloaded to date.", "VALIDATION");
        }

        var (rows, chargeTypes) = await _reports.ReportAsync(query, cancellationToken);
        var seesCharges = permissions.Contains(Permissions.Containers.ChargesView);
        var seesPayments = permissions.Contains(Permissions.Purchase.PaymentsView);

        foreach (var row in rows)
        {
            row.StatusName = row.IsPending
                ? "Not loaded"
                : row.ContainerStatus is { } s && StatusNames.TryGetValue(s, out var name) ? name : string.Empty;
            row.Alerts = AlertsOf(row);

            if (!seesCharges)
            {
                row.Charges = null;
                row.TransportBase = null;
                row.ChargesBase = null;
                row.TransportInvoices = null;
                row.TransportReferences = null;
            }

            if (!seesPayments)
            {
                row.PaidDates = null;
                row.PaymentReferences = null;
                row.PaymentStatus = null;
            }
        }

        // One column per charge type the rows carry, the transport ones excepted (they make TOTAL TRANSPORT AMOUNT).
        var carried = rows.Where(r => r.Charges is not null).SelectMany(r => r.Charges!.Keys).ToHashSet();
        var columns = seesCharges
            ? chargeTypes.Where(t => !t.IsTransport && carried.Contains(t.Id)).ToList()
            : [];

        return Result<ContainerReportResult>.Success(new ContainerReportResult
        {
            Rows = rows,
            ChargeTypes = columns,
            ChargesVisible = seesCharges,
            PaymentsVisible = seesPayments,
        });
    }

    /// <summary>What needs a look, in the words of the containers list.</summary>
    private static IReadOnlyList<string> AlertsOf(ContainerReportRowDto row)
    {
        var alerts = new List<string>();
        if (row.IsLate) alerts.Add("Late");
        if (row.IsFreeTimeOver) alerts.Add("Free time over");
        if (!row.IsPending)
        {
            if (row.PaymentStatus == "Not invoiced") alerts.Add("Not invoiced");
            if (row.PaymentStatus == "Not paid") alerts.Add("Not paid");
            if (row.PaymentStatus == "Partly paid") alerts.Add("Partly paid");
            if (string.IsNullOrWhiteSpace(row.ContainerNo)) alerts.Add("No container no.");
            if (string.IsNullOrWhiteSpace(row.BlNo) && row.DispatchDate is not null) alerts.Add("No B/L");
        }
        return alerts;
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ContainerReportQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await ReportAsync(query, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? string.Empty, read.Code ?? "ERROR");
        }

        var now = _clock.GetUtcNow();
        return Result<(byte[], string)>.Success((BuildWorkbook(read.Value, now), $"ContainerReport_{now:yyyyMMdd}.xlsx"));
    }

    /* ── the workbook ─────────────────────────────────────────────────────────────────────────── */

    private sealed record Column(string Title, Func<ContainerReportRowDto, object?> Value, string? Format = null, bool Sum = false,
                                 Func<ContainerReportRowDto, bool>? IsEstimate = null);

    /// <summary>
    /// The tracking sheet's layout: one header row (frozen, with the first four columns), then each stage as a section -
    /// its title, its rows, its subtotal - and the grand total. Estimates are in grey italics.
    /// </summary>
    private static byte[] BuildWorkbook(ContainerReportResult result, DateTimeOffset now)
    {
        const string Date = "dd/MM/yyyy";
        const string Amount = "#,##0.00";
        const string Count = "#,##0";

        var columns = new List<Column>
        {
            new("ORDER DATE", r => r.OrderDate, Date),
            new("INVOICE DATE", r => r.InvoiceDates),
            new("ORDER MONTH", r => r.OrderMonth),
            new("CON. REF.", r => r.ContainerRef),
            new("CONTAINER N°", r => r.ContainerNo),
            new("QTY.", r => r.Quantity, Count, true),
            new("MODEL", r => r.Model),
            new("PI N°", r => r.PiNumber),
            new("PI EXPORTER'S REF.", r => r.ExporterReferences),
            new("INVOICE N°", r => r.CommercialInvoiceNos),
            new("FOB PRICE", r => r.FobAmountBase, Amount, true, r => r.FobIsEstimate),
            new("OIL (L / UNIT)", r => r.OilQtyPerUnit, "0.##"),
        };
        if (result.PaymentsVisible)
        {
            columns.Add(new("PAID DATE", r => r.PaidDates));
            columns.Add(new("PAYMENT REFERENCE NUMBER", r => r.PaymentReferences));
        }
        columns.AddRange(
        [
            new("DISPATCH DATE (SEA)", r => r.DispatchDate, Date),
            new("ARRIVED IN PORT DATE", r => r.ArrivedPortDate, Date),
            new("LEFT PORT DATE", r => r.LeftPortDate, Date),
            new("FINAL DESTINATION", r => r.FinalDestination),
            new("TRUCK #", r => r.Trucks),
            new("OFFLOADED DATE", r => r.OffloadedDate, Date),
            new("LEAD TIME (MONTHS)", r => r.LeadTimeMonths, "0.00", false, r => r.LeadTimeSoFar),
            new("B.L.", r => r.BlNo),
            new("FERI", r => r.FeriNo),
        ]);
        if (result.ChargesVisible)
        {
            columns.Add(new("F.A. INVOICE REFERENCE", r => r.TransportReferences));
            columns.Add(new("TRANSPORT INVOICES", r => r.TransportInvoices));
            columns.Add(new("TOTAL TRANSPORT AMOUNT", r => r.TransportBase, Amount, true));
            foreach (var type in result.ChargeTypes)
            {
                var id = type.Id;
                columns.Add(new(type.ChargeName.ToUpperInvariant(),
                    r => r.Charges is not null && r.Charges.TryGetValue(id, out var a) ? a : null, Amount, true));
            }
            columns.Add(new("TOTAL CHARGES", r => r.ChargesBase, Amount, true));
        }
        columns.AddRange(
        [
            new("TOTAL EXPENSES", r => r.TotalExpensesBase, Amount, true, r => r.FobIsEstimate),
            new("COST PER UNIT", r => r.CostPerUnitBase, Amount, false, r => r.CostIsEstimate),
            new("STATUS", r => r.StatusName),
        ]);
        if (result.PaymentsVisible) columns.Add(new("PAYMENT STATUS", r => r.PaymentStatus));
        columns.AddRange(
        [
            new("PO N°", r => r.PoNumber),
            new("SYSTEM INVOICE N°", r => r.InvoiceNumbers),
            new("GOODS RECEIPT N°", r => r.GoodsReceiptNumbers),
            new("SUPPLIER", r => r.SupplierName),
            new("WAREHOUSE", r => r.WarehouseCode),
            new("ALERTS", r => r.Alerts.Count == 0 ? null : string.Join(", ", r.Alerts)),
        ]);

        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Container Report");
        var last = columns.Count;

        sheet.Cell(1, 1).Value = "CONTAINER REPORT";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;
        sheet.Cell(2, 1).Value =
            $"As of {now:dd/MM/yyyy}. Amounts in the base currency. Grey italics: an estimate until the goods are received (a lead time: so far).";

        var row = 4;
        for (var i = 0; i < last; i++) sheet.Cell(row, i + 1).Value = columns[i].Title;
        var header = sheet.Range(row, 1, row, last);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromArgb(0x1F, 0x4E, 0x79);
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.WrapText = true;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        sheet.Row(row).Height = 32;
        sheet.SheetView.Freeze(row, 4);

        foreach (var stage in result.Rows.GroupBy(r => r.StageLabel).OrderBy(g => g.Min(r => r.StageSort)).ThenBy(g => g.Key))
        {
            row++;
            var title = sheet.Range(row, 1, row, last);
            sheet.Cell(row, 1).Value = stage.Key.ToUpperInvariant();
            title.Style.Font.Bold = true;
            title.Style.Fill.BackgroundColor = XLColor.FromArgb(0xD9, 0xE2, 0xF3);

            foreach (var item in stage)
            {
                row++;
                for (var i = 0; i < last; i++) Write(sheet.Cell(row, i + 1), columns[i], item);
            }

            row++;
            WriteTotals(sheet, row, columns, stage.ToList(),
                $"Subtotal {stage.Key}: {stage.Count():N0} lines, {stage.Select(r => r.ContainerId).Where(id => id is not null).Distinct().Count():N0} containers");
            sheet.Range(row, 1, row, last).Style.Fill.BackgroundColor = XLColor.FromArgb(0xF2, 0xF2, 0xF2);
        }

        row += 2;
        WriteTotals(sheet, row, columns, result.Rows,
            $"Total: {result.Rows.Count:N0} lines, {result.Rows.Select(r => r.ContainerId).Where(id => id is not null).Distinct().Count():N0} containers");
        sheet.Range(row, 1, row, last).Style.Border.TopBorder = XLBorderStyleValues.Thin;

        sheet.Columns(1, last).AdjustToContents(5, row);
        foreach (var column in sheet.Columns(1, last)) column.Width = Math.Min(Math.Max(column.Width, 10), 45);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static void Write(IXLCell cell, Column column, ContainerReportRowDto row)
    {
        switch (column.Value(row))
        {
            case null: cell.Value = Blank.Value; break;
            case DateTime d: cell.Value = d; break;
            case decimal m: cell.Value = m; break;
            case int n: cell.Value = n; break;
            case var other: cell.Value = other.ToString(); break;
        }
        if (column.Format is not null) cell.Style.NumberFormat.Format = column.Format;
        if (column.IsEstimate?.Invoke(row) == true)
        {
            cell.Style.Font.Italic = true;
            cell.Style.Font.FontColor = XLColor.Gray;
        }
    }

    private static void WriteTotals(IXLWorksheet sheet, int row, List<Column> columns, IReadOnlyCollection<ContainerReportRowDto> rows, string label)
    {
        sheet.Cell(row, 1).Value = label;
        for (var i = 0; i < columns.Count; i++)
        {
            if (!columns[i].Sum) continue;
            var total = rows.Sum(r => columns[i].Value(r) switch { decimal m => m, int n => n, _ => 0m });
            sheet.Cell(row, i + 1).Value = total;
            sheet.Cell(row, i + 1).Style.NumberFormat.Format = columns[i].Format ?? "#,##0.00";
        }
        sheet.Range(row, 1, row, columns.Count).Style.Font.Bold = true;
    }
}
