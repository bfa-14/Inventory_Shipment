using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Reports › Goods on Order (script 109): everything ordered and not received yet, per item and per stage of the journey.
///
/// THE ROWS ARE THE CONTAINER REPORT'S (logistics.usp_ContainerReport without the received containers): every container
/// line not received and every approved order line with pieces still to load. THE COLUMNS ARE THEIR STAGES - the
/// procedure's StageLabel, worked out from each container's movements - so they follow the legs the containers really
/// travel (a new route, a new border post, a new port is a new column by itself); "Order pending - {month}" of every month
/// is one column. A container of two items counts in each item's row and once in every total. The containers of pieces not
/// on a container yet are estimated from the item's Container unit.
/// </summary>
public sealed class GoodsOnOrderReportService : IGoodsOnOrderReportService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string PendingKey = "Pending";

    private readonly IContainerReportRepository _reports;
    private readonly TimeProvider _clock;

    public GoodsOnOrderReportService(IContainerReportRepository reports, TimeProvider clock)
    {
        _reports = reports;
        _clock = clock;
    }

    public async Task<Result<GoodsOnOrderReportResult>> ReportAsync(
        GoodsOnOrderReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Reports.GoodsOnOrderView))
        {
            return Result<GoodsOnOrderReportResult>.Failure(
                ErrorType.Forbidden, $"This action needs the {Permissions.Reports.GoodsOnOrderView} permission.", ForbiddenCode);
        }

        var (rows, _) = await _reports.ReportAsync(new ContainerReportQuery
        {
            Search = query.Search,
            SupplierId = query.SupplierId,
            ItemId = query.ItemId,
            ItemFamilyId = query.ItemFamilyId,
            BranchId = query.BranchId,
            OrderDateTo = query.OrderDateTo,
            IncludePending = true,
            IncludeReceived = false,
        }, cancellationToken);

        var seesCharges = permissions.Contains(Permissions.Containers.ChargesView);
        var seesPayments = permissions.Contains(Permissions.Purchase.PaymentsView);
        var stageKeys = new Dictionary<string, string>();
        foreach (var row in rows)
        {
            stageKeys[row.RowKey] = KeyOf(row);
            // The drill-down reads no charge per type; the rest follows the Container Report's rule.
            row.Charges = null;
            if (!seesCharges)
            {
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

        // The columns: each stage the goods are at, in the order of the journey.
        var stages = rows
            .GroupBy(r => stageKeys[r.RowKey])
            .Select(g => new GoodsOnOrderStageDto
            {
                Key = g.Key,
                Label = g.Key == PendingKey ? "Order pending" : g.Key,
                Sort = g.Min(r => r.StageSort),
                Kind = KindOf(g.Min(r => r.StageSort)),
            })
            .OrderBy(s => s.Sort)
            .ThenBy(s => s.Label, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var pcs = await _reports.PcsPerContainerAsync(rows.Select(r => r.ItemId).Distinct().ToList(), cancellationToken);

        GoodsOnOrderCellDto Cell(IReadOnlyCollection<ContainerReportRowDto> set)
        {
            var notLoaded = set.Where(r => r.IsPending).GroupBy(r => r.ItemId).Select(g => (g.Key, Qty: g.Sum(r => r.Quantity))).ToList();
            var known = notLoaded.Where(x => pcs.ContainsKey(x.Key)).Sum(x => (int)Math.Ceiling(x.Qty / pcs[x.Key]));
            return new GoodsOnOrderCellDto
            {
                Quantity = set.Sum(r => r.Quantity),
                Containers = set.Where(r => r.ContainerId is not null).Select(r => r.ContainerId).Distinct().Count(),
                PiecesNotLoaded = notLoaded.Sum(x => x.Qty),
                EstimatedContainers = notLoaded.Count == 0 ? null : known,
                EstimateIncomplete = notLoaded.Any(x => !pcs.ContainsKey(x.Key)),
            };
        }

        Dictionary<string, GoodsOnOrderCellDto> Cells(IEnumerable<ContainerReportRowDto> set)
            => set.GroupBy(r => stageKeys[r.RowKey]).ToDictionary(g => g.Key, g => Cell(g.ToList()));

        var items = rows
            .GroupBy(r => r.ItemId)
            .Select(g =>
            {
                var first = g.First();
                return new GoodsOnOrderItemDto
                {
                    ItemId = first.ItemId,
                    ItemCode = first.ItemCode,
                    ItemName = first.Model,
                    RootFamilyName = first.RootFamilyName,
                    PcsPerContainer = pcs.TryGetValue(first.ItemId, out var p) ? p : null,
                    Cells = Cells(g),
                    Total = Cell(g.ToList()),
                };
            })
            .OrderBy(i => i.RootFamilyName ?? "~")
            .ThenBy(i => i.ItemCode, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var families = rows
            .GroupBy(r => r.RootFamilyName ?? "No family")
            .Select(g => new GoodsOnOrderFamilyDto { RootFamilyName = g.Key, Cells = Cells(g), Total = Cell(g.ToList()) })
            .OrderBy(f => f.RootFamilyName == "No family" ? "~" : f.RootFamilyName)
            .ToList();

        return Result<GoodsOnOrderReportResult>.Success(new GoodsOnOrderReportResult
        {
            Stages = stages,
            Items = items,
            Families = families,
            Totals = Cells(rows),
            GrandTotal = Cell(rows),
            Rows = rows,
            StageKeys = stageKeys,
            GeneratedAtUtc = _clock.GetUtcNow(),
            GeneratedBy = userName,
        });
    }

    /// <summary>"Pending" for every order month (StageSort 10.x), else the Container Report's stage label.</summary>
    private static string KeyOf(ContainerReportRowDto row) => Math.Floor(row.StageSort) == 10 ? PendingKey : row.StageLabel;

    /// <summary>The Container Report's StageSort in words: 20 at sea, 30 at port, 40 / 55 on the road, 50 at a place, 60 delivered.</summary>
    private static string KindOf(decimal sort) => (int)Math.Floor(sort) switch
    {
        10 => "Pending",
        20 => "AtSea",
        30 => "AtPort",
        40 or 55 => "OnTheRoad",
        50 => "AtPlace",
        60 => "Delivered",
        _ => "Other",
    };

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        GoodsOnOrderReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var read = await ReportAsync(query, userName, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? string.Empty, read.Code ?? "ERROR");
        }

        var report = read.Value;
        return Result<(byte[], string)>.Success((BuildWorkbook(report), $"GoodsOnOrder_{report.GeneratedAtUtc:yyyyMMdd}.xlsx"));
    }

    /* ── the workbook ─────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The team's "MOVEMENT SUMMARY": two header rows (each stage over its QTY. and CONTAINERS), the items by top family with
    /// a total per family, the general total of containers, and the notes. An estimated container count reads "≈ 30".
    /// </summary>
    private static byte[] BuildWorkbook(GoodsOnOrderReportResult report)
    {
        var navy = XLColor.FromArgb(0x1F, 0x4E, 0x79);
        var band = XLColor.FromArgb(0xD9, 0xE2, 0xF3);
        var sub = XLColor.FromArgb(0xF2, 0xF2, 0xF2);
        var columns = report.Stages.Select(s => (s.Key, Title: s.Label.ToUpperInvariant())).ToList();
        columns.Add(("__total", "GRAND TOTAL"));
        var last = 1 + columns.Count * 2;

        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Goods on order");

        sheet.Cell(1, 1).Value = "MOVEMENT SUMMARY - GOODS ON ORDER";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;
        sheet.Cell(2, 1).Value = $"Ordered and not received yet, as of {report.GeneratedAtUtc:dd/MM/yyyy HH:mm} UTC by {report.GeneratedBy}.";

        const int head = 4;
        sheet.Cell(head, 1).Value = "MODEL";
        sheet.Range(head, 1, head + 1, 1).Merge();
        for (var c = 0; c < columns.Count; c++)
        {
            var col = 2 + c * 2;
            sheet.Cell(head, col).Value = columns[c].Title;
            sheet.Range(head, col, head, col + 1).Merge();
            sheet.Cell(head + 1, col).Value = "QTY.";
            sheet.Cell(head + 1, col + 1).Value = "CONTAINERS";
        }
        var header = sheet.Range(head, 1, head + 1, last);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = navy;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.WrapText = true;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        sheet.Row(head).Height = 32;
        sheet.SheetView.Freeze(head + 1, 1);

        void Write(int row, IReadOnlyDictionary<string, GoodsOnOrderCellDto> cells, GoodsOnOrderCellDto total, bool quantities = true)
        {
            for (var c = 0; c < columns.Count; c++)
            {
                var cell = columns[c].Key == "__total" ? total : cells.GetValueOrDefault(columns[c].Key);
                var col = 2 + c * 2;
                if (cell is null || (cell.Quantity == 0 && cell.Containers == 0))
                {
                    if (quantities) sheet.Cell(row, col).Value = "-";
                    sheet.Cell(row, col + 1).Value = "-";
                    continue;
                }
                if (quantities)
                {
                    sheet.Cell(row, col).Value = cell.Quantity;
                    sheet.Cell(row, col).Style.NumberFormat.Format = "#,##0";
                }
                var estimate = cell.EstimatedContainers ?? 0;
                if (estimate > 0 || cell.EstimateIncomplete)
                {
                    sheet.Cell(row, col + 1).Value = cell.Containers + estimate == 0 ? "?" : $"≈ {cell.Containers + estimate:N0}{(cell.EstimateIncomplete ? "+" : "")}";
                    sheet.Cell(row, col + 1).Style.Font.Italic = true;
                }
                else
                {
                    sheet.Cell(row, col + 1).Value = cell.Containers;
                    sheet.Cell(row, col + 1).Style.NumberFormat.Format = "#,##0";
                }
            }
            sheet.Range(row, 2, row, last).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        }

        var r = head + 1;
        foreach (var family in report.Families)
        {
            r++;
            sheet.Cell(r, 1).Value = family.RootFamilyName.ToUpperInvariant();
            sheet.Range(r, 1, r, last).Style.Font.Bold = true;
            sheet.Range(r, 1, r, last).Style.Fill.BackgroundColor = band;
            foreach (var item in report.Items.Where(i => (i.RootFamilyName ?? "No family") == family.RootFamilyName))
            {
                r++;
                sheet.Cell(r, 1).Value = item.ItemName;
                Write(r, item.Cells, item.Total);
            }
            r++;
            sheet.Cell(r, 1).Value = $"TOTAL {family.RootFamilyName.ToUpperInvariant()}";
            Write(r, family.Cells, family.Total);
            sheet.Range(r, 1, r, last).Style.Font.Bold = true;
            sheet.Range(r, 1, r, last).Style.Fill.BackgroundColor = sub;
        }

        r += 2;
        sheet.Cell(r, 1).Value = "GENERAL TOTAL CONTAINERS";
        Write(r, report.Totals, report.GrandTotal, quantities: false);
        sheet.Range(r, 1, r, last).Style.Font.Bold = true;
        sheet.Range(r, 1, r, last).Style.Border.TopBorder = XLBorderStyleValues.Thin;

        r += 2;
        sheet.Cell(r, 1).Value = "A mixed container counts under each item it holds; the family totals and the general total count it once.";
        sheet.Cell(r + 1, 1).Value = "≈: pieces not on a container yet, estimated from the item's container unit (+: some items have none, their containers are unknown).";
        sheet.Range(r, 1, r + 1, 1).Style.Font.Italic = true;

        sheet.Column(1).Width = 34;
        for (var c = 2; c <= last; c++) sheet.Column(c).Width = 12;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
