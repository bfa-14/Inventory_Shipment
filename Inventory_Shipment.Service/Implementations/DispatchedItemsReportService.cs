using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Reports › Dispatched Items (script 106): the items dispatched in a period, as the item balance and as the items /
/// containers. ITS ROWS ARE THE CONTAINER REPORT'S (logistics.usp_ContainerReport by dispatch date and country of
/// loading), so the two reports never disagree; this service adds them up per item and top family and says where each
/// line is now.
///
/// THE SERVER STRIPS, THE PAGE HIDES, as on the Container Report: without View Container Charges every charge figure,
/// the oil deduction included, leaves the API null; without View Supplier Payments the payment columns do.
/// </summary>
public sealed class DispatchedItemsReportService : IDispatchedItemsReportService
{
    private const string ForbiddenCode = "FORBIDDEN";

    private static readonly Dictionary<byte, string> StatusNames = new()
    {
        [1] = "Draft", [2] = "Confirmed", [3] = "In Transit", [4] = "At Port", [5] = "Cleared",
        [6] = "Offloaded", [7] = "Closed", [8] = "Cancelled",
    };

    private static readonly Dictionary<string, string> LocationNames = new()
    {
        [DispatchedLocation.AtSea] = "At sea",
        [DispatchedLocation.AtPort] = "At port",
        [DispatchedLocation.OnTheRoad] = "On the road",
        [DispatchedLocation.Offloaded] = "Offloaded",
    };

    private readonly IContainerReportRepository _reports;
    private readonly IContainerChargeReportRepository _currency;
    private readonly TimeProvider _clock;

    public DispatchedItemsReportService(IContainerReportRepository reports, IContainerChargeReportRepository currency, TimeProvider clock)
    {
        _reports = reports;
        _currency = currency;
        _clock = clock;
    }

    public async Task<Result<DispatchedItemsReportResult>> ReportAsync(
        DispatchedItemsReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Reports.DispatchedItemsView))
        {
            return Result<DispatchedItemsReportResult>.Failure(
                ErrorType.Forbidden, $"This action needs the {Permissions.Reports.DispatchedItemsView} permission.", ForbiddenCode);
        }

        if (query.DispatchFrom is not { } from || query.DispatchTo is not { } to)
        {
            return Result<DispatchedItemsReportResult>.Failure(
                ErrorType.Validation, "Choose the dispatch date from and to.", "VALIDATION");
        }

        if (from > to)
        {
            return Result<DispatchedItemsReportResult>.Failure(
                ErrorType.Validation, "Date From is after Date To.", "VALIDATION");
        }

        var country = string.IsNullOrWhiteSpace(query.LoadingCountry) ? null : query.LoadingCountry.Trim().ToUpperInvariant();
        if (country is { Length: not 2 })
        {
            return Result<DispatchedItemsReportResult>.Failure(
                ErrorType.Validation, "The country of loading is a two-letter code (IN).", "VALIDATION");
        }

        var (rows, chargeTypes) = await _reports.ReportAsync(new ContainerReportQuery
        {
            Search = query.Search,
            SupplierId = query.SupplierId,
            ItemId = query.ItemId,
            ItemFamilyId = query.ItemFamilyId,
            DispatchFrom = from,
            DispatchTo = to,
            LoadingCountry = country,
            IncludePending = false,
            IncludeReceived = true,
        }, cancellationToken);

        var seesCharges = permissions.Contains(Permissions.Containers.ChargesView);
        var seesPayments = permissions.Contains(Permissions.Purchase.PaymentsView);
        var deductions = chargeTypes.Where(t => t.IsDeduction).ToList();
        var deductionIds = deductions.Select(t => t.Id).ToHashSet();

        var locations = new Dictionary<string, string>();
        var kept = new List<ContainerReportRowDto>();
        foreach (var row in rows)
        {
            var location = LocationOf(row);
            if (!string.IsNullOrEmpty(query.Location) && query.Location != "All" && query.Location != location) continue;
            locations[row.RowKey] = location;

            row.StatusName = row.ContainerStatus is { } s && StatusNames.TryGetValue(s, out var name) ? name : string.Empty;
            if (seesCharges)
            {
                // Deductions are stored negative (taken off the cost): the report says what was deducted, positive.
                var deducted = row.Charges?.Where(c => deductionIds.Contains(c.Key)).Sum(c => -c.Value) ?? 0m;
                row.DeductionBase = deducted == 0m ? null : deducted;
            }
            else
            {
                row.TransportBase = null;
                row.ChargesBase = null;
                row.TransportInvoices = null;
                row.TransportReferences = null;
            }

            // The page reads none of the charges per type: the deduction is worked out above.
            row.Charges = null;

            if (!seesPayments)
            {
                row.PaidDates = null;
                row.PaymentReferences = null;
                row.PaymentStatus = null;
            }

            kept.Add(row);
        }

        var items = kept
            .GroupBy(r => r.ItemId)
            .Select(g =>
            {
                var first = g.First();
                var quantity = g.Sum(r => r.Quantity);
                var fob = g.Sum(r => r.FobAmountBase ?? 0m);
                var oil = g.Sum(r => r.TotalOilQty ?? 0m);
                int At(string where) => g.Where(r => locations[r.RowKey] == where).Sum(r => r.Quantity);
                return new DispatchedItemDto
                {
                    ItemId = first.ItemId,
                    ItemCode = first.ItemCode,
                    ItemName = first.Model,
                    ItemFamilyName = first.ItemFamilyName,
                    RootFamilyName = first.RootFamilyName,
                    Containers = g.Select(r => r.ContainerId).Distinct().Count(),
                    Quantity = quantity,
                    FobAmountBase = fob,
                    FobIsEstimate = g.Any(r => r.FobIsEstimate),
                    FobPerUnitBase = quantity == 0 ? null : Math.Round(fob / quantity, 4),
                    OilQty = oil == 0m ? null : oil,
                    OilIncludedLines = g.Count(r => r.OilIncluded == true),
                    DeductionBase = seesCharges ? g.Sum(r => r.DeductionBase ?? 0m) : null,
                    AtSea = At(DispatchedLocation.AtSea),
                    AtPort = At(DispatchedLocation.AtPort),
                    OnTheRoad = At(DispatchedLocation.OnTheRoad),
                    Offloaded = At(DispatchedLocation.Offloaded),
                };
            })
            .OrderBy(i => i.RootFamilyName ?? "~")
            .ThenBy(i => i.ItemCode, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var families = kept
            .GroupBy(r => r.RootFamilyName ?? "No family")
            .Select(g => new DispatchedFamilyTotalDto
            {
                RootFamilyName = g.Key,
                Containers = g.Select(r => r.ContainerId).Distinct().Count(),
                Quantity = g.Sum(r => r.Quantity),
                FobAmountBase = g.Sum(r => r.FobAmountBase ?? 0m),
                DeductionBase = seesCharges ? g.Sum(r => r.DeductionBase ?? 0m) : null,
            })
            .OrderBy(f => f.RootFamilyName)
            .ToList();

        // A container counts once, at the place of its first line (all its lines travel together).
        var containers = kept.GroupBy(r => r.ContainerId).Select(g => locations[g.First().RowKey]).ToList();
        var totalOil = kept.Sum(r => r.TotalOilQty ?? 0m);
        var totals = new DispatchedItemsTotalsDto
        {
            Containers = containers.Count,
            FobAmountBase = kept.Sum(r => r.FobAmountBase ?? 0m),
            OilQty = totalOil == 0m ? null : totalOil,
            DeductionBase = seesCharges ? kept.Sum(r => r.DeductionBase ?? 0m) : null,
            ContainersAtSea = containers.Count(l => l == DispatchedLocation.AtSea),
            ContainersAtPort = containers.Count(l => l == DispatchedLocation.AtPort),
            ContainersOnTheRoad = containers.Count(l => l == DispatchedLocation.OnTheRoad),
            ContainersOffloaded = containers.Count(l => l == DispatchedLocation.Offloaded),
        };

        // Lines grouped by item, then by dispatch date and container, as the team's sheet.
        var ordered = kept
            .OrderBy(r => items.FindIndex(i => i.ItemId == r.ItemId))
            .ThenBy(r => r.DispatchDate)
            .ThenBy(r => r.ContainerRef, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return Result<DispatchedItemsReportResult>.Success(new DispatchedItemsReportResult
        {
            DispatchFrom = from,
            DispatchTo = to,
            LoadingCountry = country,
            Items = items,
            Families = families,
            Totals = totals,
            Rows = ordered,
            Locations = locations,
            DeductionName = deductions.Count switch { 0 => null, 1 => deductions[0].ChargeName, _ => "Deductions" },
            DeductionVisible = seesCharges,
            PaymentsVisible = seesPayments,
            BaseCurrencyCode = await _currency.BaseCurrencyCodeAsync(cancellationToken) ?? "USD",
            GeneratedAtUtc = _clock.GetUtcNow(),
            GeneratedBy = userName,
        });
    }

    /// <summary>
    /// Where a line is now, from the Container Report's stage: received (Offloaded / Closed), a vessel leg (20), at a sea
    /// port (30), anywhere after the port (40-60). A container followed by typed dates has no stage: its status says it.
    /// </summary>
    private static string LocationOf(ContainerReportRowDto row)
    {
        if (row.ContainerStatus is 6 or 7) return DispatchedLocation.Offloaded;
        return (int)Math.Floor(row.StageSort) switch
        {
            20 => DispatchedLocation.AtSea,
            30 => DispatchedLocation.AtPort,
            40 or 50 or 55 or 60 => DispatchedLocation.OnTheRoad,
            _ => row.ContainerStatus switch
            {
                4 => DispatchedLocation.AtPort,
                5 => DispatchedLocation.OnTheRoad,
                _ => DispatchedLocation.AtSea,
            },
        };
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        DispatchedItemsReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var read = await ReportAsync(query, userName, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? string.Empty, read.Code ?? "ERROR");
        }

        var report = read.Value;
        return Result<(byte[], string)>.Success(
            (BuildWorkbook(report), $"DispatchedItems_{report.DispatchFrom:yyyyMMdd}-{report.DispatchTo:yyyyMMdd}.xlsx"));
    }

    /* ── the workbook ─────────────────────────────────────────────────────────────────────────── */

    private sealed record Column(string Title, Func<ContainerReportRowDto, object?> Value, string? Format = null, bool Sum = false);

    /// <summary>
    /// The team's sheet on one worksheet: the title and the period, the item balance (one row per item, a subtotal per top
    /// family, the total), then the items / containers grouped by item with a subtotal each.
    /// </summary>
    private static byte[] BuildWorkbook(DispatchedItemsReportResult report)
    {
        const string Date = "dd/MM/yyyy";
        const string Amount = "#,##0.00";
        const string Count = "#,##0";
        var navy = XLColor.FromArgb(0x1F, 0x4E, 0x79);
        var band = XLColor.FromArgb(0xD9, 0xE2, 0xF3);
        var sub = XLColor.FromArgb(0xF2, 0xF2, 0xF2);
        var deduction = report.DeductionName ?? "Oil deduction";

        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Dispatched items");

        var r = 1;
        sheet.Cell(r, 1).Value = report.LoadingCountry == "IN"
            ? $"DISPATCH FROM INDIA - {report.DispatchFrom:MMM yyyy}".ToUpperInvariant()
            : $"DISPATCHED ITEMS - {report.DispatchFrom:MMM yyyy}".ToUpperInvariant();
        sheet.Cell(r, 1).Style.Font.Bold = true;
        sheet.Cell(r, 1).Style.Font.FontSize = 14;
        r += 2;
        void Info(string label, string value)
        {
            sheet.Cell(r, 1).Value = label;
            sheet.Cell(r, 1).Style.Font.Bold = true;
            sheet.Cell(r, 2).Value = value;
            r++;
        }

        Info("Dispatched", $"{report.DispatchFrom:dd/MM/yyyy} to {report.DispatchTo:dd/MM/yyyy}");
        Info("Loaded in", report.LoadingCountry ?? "Any country");
        Info("Amounts", $"{report.BaseCurrencyCode}. Grey italics: an FOB estimate until the goods are received.");
        if (!report.DeductionVisible) Info(deduction, "not shown: it needs the View Container Charges permission");
        Info("Run", $"{report.GeneratedAtUtc:dd/MM/yyyy HH:mm} UTC by {report.GeneratedBy}");
        r++;

        /* the item balance */
        var balance = new List<(string Title, Func<DispatchedItemDto, object?> Value, Func<DispatchedFamilyTotalDto, object?>? Family, string? Format)>
        {
            ("ITEM", i => i.ItemCode, f => $"Total {f.RootFamilyName}", null),
            ("MODEL", i => i.ItemName, null, null),
            ("CONTAINERS", i => i.Containers, f => f.Containers, Count),
            ("QTY", i => i.Quantity, f => f.Quantity, Count),
            ($"FOB VALUE ({report.BaseCurrencyCode})", i => i.FobAmountBase, f => f.FobAmountBase, Amount),
            ("FOB / UNIT", i => i.FobPerUnitBase, null, Amount),
            ("OIL QTY", i => i.OilQty is { } oil ? oil : i.OilIncludedLines > 0 ? "Included" : null, null, "#,##0.##"),
        };
        if (report.DeductionVisible) balance.Add((deduction.ToUpperInvariant(), i => i.DeductionBase, f => f.DeductionBase, Amount));
        balance.AddRange(
        [
            ("AT SEA", i => i.AtSea, null, Count),
            ("AT PORT", i => i.AtPort, null, Count),
            ("ON THE ROAD", i => i.OnTheRoad, null, Count),
            ("OFFLOADED", i => i.Offloaded, null, Count),
        ]);

        for (var c = 0; c < balance.Count; c++) sheet.Cell(r, c + 1).Value = balance[c].Title;
        Header(sheet.Range(r, 1, r, balance.Count));
        foreach (var family in report.Families)
        {
            foreach (var item in report.Items.Where(i => (i.RootFamilyName ?? "No family") == family.RootFamilyName))
            {
                r++;
                for (var c = 0; c < balance.Count; c++)
                {
                    Put(sheet.Cell(r, c + 1), balance[c].Value(item), balance[c].Format);
                    if (balance[c].Title.StartsWith("FOB") && item.FobIsEstimate) Estimate(sheet.Cell(r, c + 1));
                }
            }
            r++;
            for (var c = 0; c < balance.Count; c++)
            {
                if (balance[c].Family is { } total) Put(sheet.Cell(r, c + 1), total(family), balance[c].Format);
            }
            sheet.Range(r, 1, r, balance.Count).Style.Font.Bold = true;
            sheet.Range(r, 1, r, balance.Count).Style.Fill.BackgroundColor = sub;
        }
        r++;
        sheet.Cell(r, 1).Value = "TOTAL";
        sheet.Cell(r, 3).Value = report.Totals.Containers;
        sheet.Cell(r, 5).Value = report.Totals.FobAmountBase;
        sheet.Cell(r, 5).Style.NumberFormat.Format = Amount;
        if (report.Totals.OilQty is { } oilTotal) sheet.Cell(r, 7).Value = oilTotal;
        if (report.DeductionVisible && report.Totals.DeductionBase is { } d)
        {
            sheet.Cell(r, 8).Value = d;
            sheet.Cell(r, 8).Style.NumberFormat.Format = Amount;
        }
        sheet.Range(r, 1, r, balance.Count).Style.Font.Bold = true;
        sheet.Range(r, 1, r, balance.Count).Style.Border.TopBorder = XLBorderStyleValues.Thin;
        r++;
        sheet.Cell(r, 1).Value = "The quantity is added up per top family: the vehicles apart from the spare parts. A container of two items counts in both rows, once in the total.";
        sheet.Cell(r, 1).Style.Font.Italic = true;
        r += 2;

        /* the items / containers */
        var columns = new List<Column>
        {
            new("ORDER DATE", x => x.OrderDate, Date),
            new("ORDER MONTH", x => x.OrderMonth),
            new("CON. REF.", x => x.ContainerRef),
            new("CONTAINER N°", x => x.ContainerNo),
            new("QTY.", x => x.Quantity, Count, true),
            new("MODEL", x => x.Model),
            new("PI N°", x => x.PiNumber),
            new("PI EXPORTER'S REF.", x => x.ExporterReferences),
            new("INVOICE N°", x => x.CommercialInvoiceNos),
            new("C.I. & P.L. DATE", x => x.InvoiceDates),
            new("FOB PRICE", x => x.FobAmountBase, Amount, true),
            new("OIL QTY", x => x.TotalOilQty is { } oil ? oil : x.OilIncluded == true ? "Included" : null, "#,##0.##", true),
        };
        if (report.DeductionVisible) columns.Add(new(deduction.ToUpperInvariant(), x => x.DeductionBase, Amount, true));
        if (report.PaymentsVisible)
        {
            columns.Add(new("PAID DATE", x => x.PaidDates));
            columns.Add(new("PAYMENT REFERENCE NUMBER", x => x.PaymentReferences));
        }
        columns.AddRange(
        [
            new("DISPATCH DATE", x => x.DispatchDate, Date),
            new("ARRIVED IN PORT DATE", x => x.ArrivedPortDate, Date),
            new("LEFT PORT DATE", x => x.LeftPortDate, Date),
            new("FINAL DESTINATION", x => x.FinalDestination),
            new("TRUCK #", x => x.Trucks),
            new("OFFLOADED", x => x.OffloadedDate, Date),
            new("LEAD TIME (MONTHS)", x => x.LeadTimeMonths, "0.00"),
            new("WHERE NOW", x => LocationNames.GetValueOrDefault(report.Locations.GetValueOrDefault(x.RowKey) ?? "")),
            new("CURRENT LOCATION", x => x.StageLabel),
            new("STATUS", x => x.StatusName),
            new("B.L.", x => x.BlNo),
            new("SUPPLIER", x => x.SupplierName),
            new("PO N°", x => x.PoNumber),
        ]);

        var headerRow = r;
        for (var c = 0; c < columns.Count; c++) sheet.Cell(r, c + 1).Value = columns[c].Title;
        Header(sheet.Range(r, 1, r, columns.Count));

        foreach (var group in report.Rows.GroupBy(x => x.ItemId))
        {
            var first = group.First();
            r++;
            sheet.Cell(r, 1).Value = $"{first.ItemCode} · {first.Model}";
            sheet.Range(r, 1, r, columns.Count).Style.Font.Bold = true;
            sheet.Range(r, 1, r, columns.Count).Style.Fill.BackgroundColor = band;
            foreach (var line in group)
            {
                r++;
                for (var c = 0; c < columns.Count; c++)
                {
                    Put(sheet.Cell(r, c + 1), columns[c].Value(line), columns[c].Format);
                    if (columns[c].Title == "FOB PRICE" && line.FobIsEstimate) Estimate(sheet.Cell(r, c + 1));
                    if (columns[c].Title == "LEAD TIME (MONTHS)" && line.LeadTimeSoFar) Estimate(sheet.Cell(r, c + 1));
                }
            }
            r++;
            sheet.Cell(r, 1).Value = $"Subtotal {first.ItemCode}: {group.Select(x => x.ContainerId).Distinct().Count():N0} containers";
            Totals(sheet, r, columns, group.ToList());
            sheet.Range(r, 1, r, columns.Count).Style.Fill.BackgroundColor = sub;
        }

        r += 2;
        sheet.Cell(r, 1).Value = $"Total: {report.Totals.Containers:N0} containers";
        Totals(sheet, r, columns, report.Rows);
        sheet.Range(r, 1, r, columns.Count).Style.Border.TopBorder = XLBorderStyleValues.Thin;

        sheet.SheetView.Freeze(0, 1);
        sheet.Columns(1, Math.Max(columns.Count, balance.Count)).AdjustToContents(headerRow, r);
        foreach (var column in sheet.Columns(1, Math.Max(columns.Count, balance.Count)))
        {
            column.Width = Math.Min(Math.Max(column.Width, 10), 40);
        }

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();

        void Header(IXLRange range)
        {
            range.Style.Font.Bold = true;
            range.Style.Fill.BackgroundColor = navy;
            range.Style.Font.FontColor = XLColor.White;
            range.Style.Alignment.WrapText = true;
            range.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            sheet.Row(range.FirstRow().RowNumber()).Height = 30;
        }
    }

    private static void Put(IXLCell cell, object? value, string? format)
    {
        switch (value)
        {
            case null: cell.Value = Blank.Value; return;
            case DateTime d: cell.Value = d; break;
            case decimal m: cell.Value = m; break;
            case int n: cell.Value = n; break;
            case var other: cell.Value = other.ToString(); return;
        }
        if (format is not null) cell.Style.NumberFormat.Format = format;
    }

    private static void Estimate(IXLCell cell)
    {
        cell.Style.Font.Italic = true;
        cell.Style.Font.FontColor = XLColor.Gray;
    }

    private static void Totals(IXLWorksheet sheet, int row, List<Column> columns, IReadOnlyCollection<ContainerReportRowDto> rows)
    {
        for (var c = 0; c < columns.Count; c++)
        {
            if (!columns[c].Sum) continue;
            var total = rows.Sum(x => columns[c].Value(x) switch { decimal m => m, int n => n, _ => 0m });
            sheet.Cell(row, c + 1).Value = total;
            sheet.Cell(row, c + 1).Style.NumberFormat.Format = columns[c].Format ?? "#,##0.00";
        }
        sheet.Range(row, 1, row, columns.Count).Style.Font.Bold = true;
    }
}
