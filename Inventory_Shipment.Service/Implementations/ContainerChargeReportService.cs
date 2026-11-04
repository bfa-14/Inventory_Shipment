using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Reports › Container Charges (script 105): the containers offloaded or dispatched in a period and, per charge type
/// asked, the charge entered or missing, its amount and what is paid of it - the logistics team's "charge per
/// CONTAINER" sheet.
///
/// ONE CELL PER CONTAINER AND TYPE: the type's Draft and Posted charges added up in the base currency; Entered when one
/// is posted, Draft when all are drafts, Missing when none. Paid when every charge's posted payments cover it in its own
/// currency, Partly paid when something is, Unpaid when nothing is; a deduction (script 102) is never paid (NotPayable).
///
/// THE SERVER STRIPS, THE PAGE HIDES: without View Supplier Payments every paid figure and payment status is null and
/// the payment filter is ignored.
/// </summary>
public sealed class ContainerChargeReportService : IContainerChargeReportService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string ValidationCode = "VALIDATION";
    private const decimal Cent = 0.005m;

    private readonly IContainerChargeReportRepository _reports;
    private readonly TimeProvider _clock;

    public ContainerChargeReportService(IContainerChargeReportRepository reports, TimeProvider clock)
    {
        _reports = reports;
        _clock = clock;
    }

    public async Task<Result<ContainerChargeReportOptions>> OptionsAsync(
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Reports.ContainerChargesView))
        {
            return Forbidden<ContainerChargeReportOptions>();
        }

        return Result<ContainerChargeReportOptions>.Success(await _reports.OptionsAsync(cancellationToken));
    }

    public Task<Result<ContainerChargeReportResult>> ReportAsync(
        ContainerChargeReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => BuildAsync(query, userName, permissions, cancellationToken);

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ContainerChargeReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var built = await BuildAsync(query, userName, permissions, cancellationToken);
        if (!built.IsSuccess)
        {
            return Result<(byte[], string)>.Failure(built.ErrorType, built.Error!, built.Code ?? ValidationCode);
        }

        var report = built.Value!;
        var period = report.DateFrom is { } f && report.DateTo is { } t ? $"_{f:yyyyMMdd}-{t:yyyyMMdd}" : "";
        return Result<(byte[], string)>.Success((BuildWorkbook(report), $"ContainerCharges{period}.xlsx"));
    }

    /* ── The report ────────────────────────────────────────────────────────────────────────────── */

    private async Task<Result<ContainerChargeReportResult>> BuildAsync(
        ContainerChargeReportQuery query, string userName, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        if (!permissions.Contains(Permissions.Reports.ContainerChargesView))
        {
            return Forbidden<ContainerChargeReportResult>();
        }

        var typeIds = (query.ChargeTypeIds ?? []).Where(x => x > 0).Distinct().ToList();
        if (typeIds.Count == 0)
        {
            return Result<ContainerChargeReportResult>.Failure(ErrorType.Validation, "Choose at least one charge type.", ValidationCode);
        }

        if (query.DateFrom is { } from && query.DateTo is { } to && from > to)
        {
            return Result<ContainerChargeReportResult>.Failure(ErrorType.Validation, "Date From is after Date To.", ValidationCode);
        }

        var basis = string.Equals(query.DateBasis, "Dispatch", StringComparison.OrdinalIgnoreCase) ? "Dispatch" : "Offload";
        var sees = permissions.Contains(Permissions.Purchase.PaymentsView);

        var data = await _reports.DataAsync(typeIds, basis, query.DateFrom, query.DateTo,
            string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(), query.SupplierId, cancellationToken);
        var types = data.ChargeTypes;
        if (types.Count == 0)
        {
            return Result<ContainerChargeReportResult>.Failure(ErrorType.Validation, "The charge types chosen do not exist.", ValidationCode);
        }

        var deductions = types.Where(x => x.IsDeduction).Select(x => x.Id).ToHashSet();
        var baseCode = await _reports.BaseCurrencyCodeAsync(cancellationToken) ?? "USD";

        var details = data.Charges.Select(c => new ContainerChargeDetailDto
        {
            ChargeId = c.ChargeId,
            ContainerId = c.ContainerId,
            ChargeTypeId = c.ChargeTypeId,
            Status = c.Status == 2 ? "Posted" : "Draft",
            ChargeDate = DateOnly.FromDateTime(c.ChargeDate),
            Reference = c.Reference,
            ProviderName = c.ProviderName,
            CurrencyCode = c.CurrencyCode,
            Amount = c.Amount,
            AmountBase = c.AmountBase,
            PaidAmount = sees ? c.PaidAmount : null,
            PaidBase = sees ? c.PaidBase : null,
            Payments = sees ? c.Payments : null,
            PaymentStatus = sees ? ChargePaymentStatus(c, deductions.Contains(c.ChargeTypeId)) : null,
        }).ToList();
        var byCell = details.ToLookup(x => (x.ContainerId, x.ChargeTypeId));

        var rows = new List<ContainerChargeRowDto>();
        foreach (var c in data.Containers)
        {
            var cells = new Dictionary<int, ContainerChargeCellDto>();
            foreach (var type in types)
            {
                cells[type.Id] = Cell([.. byCell[(c.ContainerId, type.Id)]], deductions.Contains(type.Id), sees, baseCode);
            }

            var amount = cells.Values.Sum(x => x.Amount ?? 0);
            var paid = sees ? cells.Values.Sum(x => x.Paid ?? 0) : (decimal?)null;
            var row = new ContainerChargeRowDto
            {
                ContainerId = c.ContainerId,
                ContainerRef = c.ContainerRef,
                ContainerNo = c.ContainerNo,
                BlNo = c.BlNo,
                ContainerStatus = c.ContainerStatus,
                Items = c.Items,
                Pieces = c.Pieces,
                Suppliers = c.Suppliers,
                Orders = c.Orders,
                FinalDestination = c.FinalDestination,
                StageSort = c.StageSort,
                StageLabel = c.StageLabel,
                DispatchDate = c.DispatchDate is { } d ? DateOnly.FromDateTime(d) : null,
                OffloadedDate = c.OffloadedDate is { } o ? DateOnly.FromDateTime(o) : null,
                BranchName = c.BranchName,
                WarehouseName = c.WarehouseName,
                Charges = cells,
                Amount = amount,
                Paid = paid,
                Balance = sees ? cells.Values.Sum(x => x.Balance ?? 0) : null,
            };

            if (Keep(row, query, sees))
            {
                rows.Add(row);
            }
        }

        var kept = rows.Select(x => x.ContainerId).ToHashSet();
        details = details.Where(x => kept.Contains(x.ContainerId)).ToList();

        var perType = types.ToDictionary(t => t.Id, t => new ContainerChargeTypeTotalsDto
        {
            Entered = rows.Count(r => r.Charges[t.Id].Status == "Entered"),
            Draft = rows.Count(r => r.Charges[t.Id].Status == "Draft"),
            Missing = rows.Count(r => r.Charges[t.Id].Status == "Missing"),
            Amount = rows.Sum(r => r.Charges[t.Id].Amount ?? 0),
            Paid = sees ? rows.Sum(r => r.Charges[t.Id].Paid ?? 0) : null,
            Balance = sees ? rows.Sum(r => r.Charges[t.Id].Balance ?? 0) : null,
        });

        return Result<ContainerChargeReportResult>.Success(new ContainerChargeReportResult
        {
            DateBasis = basis,
            DateFrom = query.DateFrom,
            DateTo = query.DateTo,
            ChargeTypes = types,
            Rows = rows,
            Charges = details,
            Totals = new ContainerChargeTotalsDto
            {
                Containers = rows.Count,
                WithMissing = rows.Count(r => r.Charges.Values.Any(x => x.Status == "Missing")),
                Amount = rows.Sum(x => x.Amount),
                Paid = sees ? rows.Sum(x => x.Paid ?? 0) : null,
                Balance = sees ? rows.Sum(x => x.Balance ?? 0) : null,
                PerType = perType,
            },
            SeesPayments = sees,
            BaseCurrencyCode = baseCode,
            GeneratedAtUtc = _clock.GetUtcNow().UtcDateTime,
            GeneratedBy = userName,
        });
    }

    /// <summary>A charge is paid when its posted payments cover it in its own currency.</summary>
    private static string ChargePaymentStatus(ContainerChargeRow c, bool deduction)
    {
        if (deduction) return "NotPayable";
        if (c.PaidAmount >= c.Amount - Cent) return "Paid";
        return c.PaidAmount > 0 ? "PartlyPaid" : "Unpaid";
    }

    private static ContainerChargeCellDto Cell(List<ContainerChargeDetailDto> charges, bool deduction, bool sees, string baseCode)
    {
        if (charges.Count == 0)
        {
            return new ContainerChargeCellDto { Status = "Missing" };
        }

        var amount = charges.Sum(x => x.AmountBase);
        var paid = charges.Sum(x => x.PaidBase ?? 0);
        string? paymentStatus = null;
        if (sees)
        {
            paymentStatus = deduction ? "NotPayable"
                : charges.All(x => x.PaymentStatus == "Paid") ? "Paid"
                : charges.Any(x => x.PaymentStatus is "Paid" or "PartlyPaid") ? "PartlyPaid"
                : "Unpaid";
        }

        var foreign = charges.Where(x => x.CurrencyCode is not null && x.CurrencyCode != baseCode)
            .GroupBy(x => x.CurrencyCode!)
            .Select(g => $"{g.Key} {g.Sum(x => x.Amount):N2}")
            .ToList();

        return new ContainerChargeCellDto
        {
            Status = charges.Any(x => x.Status == "Posted") ? "Entered" : "Draft",
            Count = charges.Count,
            Amount = amount,
            Paid = sees ? paid : null,
            // A deduction owes nothing; a payment above the charge never shows a negative balance.
            Balance = sees ? (deduction ? 0 : Math.Max(0, amount - paid)) : null,
            PaymentStatus = paymentStatus,
            Original = foreign.Count == 0 ? null : string.Join(", ", foreign),
        };
    }

    private static bool Keep(ContainerChargeRowDto row, ContainerChargeReportQuery query, bool sees)
    {
        var cells = row.Charges.Values;
        var entered = query.Entered?.Trim();
        if (string.Equals(entered, "Missing", StringComparison.OrdinalIgnoreCase) && cells.All(x => x.Status != "Missing")) return false;
        if (string.Equals(entered, "Entered", StringComparison.OrdinalIgnoreCase) && cells.Any(x => x.Status == "Missing")) return false;

        if (!sees) return true;
        var payment = query.Payment?.Trim();
        var payable = cells.Where(x => x.PaymentStatus is "Paid" or "PartlyPaid" or "Unpaid").ToList();
        if (string.Equals(payment, "Paid", StringComparison.OrdinalIgnoreCase))
            return payable.Count > 0 && payable.All(x => x.PaymentStatus == "Paid");
        if (string.Equals(payment, "PartlyPaid", StringComparison.OrdinalIgnoreCase))
            return payable.Any(x => x.PaymentStatus == "PartlyPaid");
        if (string.Equals(payment, "Unpaid", StringComparison.OrdinalIgnoreCase))
            return payable.Any(x => x.PaymentStatus == "Unpaid");
        return true;
    }

    private static Result<T> Forbidden<T>()
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {Permissions.Reports.ContainerChargesView} permission.", ForbiddenCode);

    /* ── Excel ─────────────────────────────────────────────────────────────────────────────────── */

    private static string StatusText(string? status) => status switch
    {
        "PartlyPaid" => "Partly paid",
        "NotPayable" => "Not payable",
        null => "",
        _ => status,
    };

    /// <summary>
    /// THE SHEET, AS THE TEAM KEEPS IT: "charge per CONTAINER", the count and the total, then # / container ref /
    /// container number / items / final destination / current location / the dates, and per charge type its status,
    /// amount, paid and payment status, rows grouped by current location with the totals at the bottom.
    /// </summary>
    private static byte[] BuildWorkbook(ContainerChargeReportResult report)
    {
        const string amountFormat = "#,##0.00;[Red]-#,##0.00";
        var sees = report.SeesPayments;

        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Charges per container");

        var r = 1;
        sheet.Cell(r, 1).Value = "Charge per container";
        sheet.Cell(r, 1).Style.Font.Bold = true;
        sheet.Cell(r, 1).Style.Font.FontSize = 14;
        r++;
        void Info(string label, string value)
        {
            sheet.Cell(r, 1).Value = label;
            sheet.Cell(r, 1).Style.Font.Bold = true;
            sheet.Cell(r, 2).Value = value;
            r++;
        }

        Info("Charge types", string.Join(", ", report.ChargeTypes.Select(x => x.ChargeName)));
        var basis = report.DateBasis == "Dispatch" ? "Dispatched" : "Offloaded";
        Info("Period", report.DateFrom is null && report.DateTo is null
            ? "Every container"
            : $"{basis} {(report.DateFrom is { } f ? $"from {f:dd/MM/yyyy} " : "")}{(report.DateTo is { } t ? $"to {t:dd/MM/yyyy}" : "")}".Trim());
        Info("Count", report.Totals.Containers.ToString("N0"));
        Info($"Total {report.BaseCurrencyCode}", report.Totals.Amount.ToString("N2"));
        if (sees)
        {
            Info($"Paid {report.BaseCurrencyCode}", (report.Totals.Paid ?? 0).ToString("N2"));
            Info($"Balance {report.BaseCurrencyCode}", (report.Totals.Balance ?? 0).ToString("N2"));
        }
        else
        {
            Info("Payments", "not shown: they need the View Supplier Payments permission");
        }

        Info("Run", $"{report.GeneratedAtUtc:dd/MM/yyyy HH:mm} UTC by {report.GeneratedBy}");
        r++;

        var columns = new List<(string Group, string Header, Func<ContainerChargeRowDto, int, XLCellValue> Row, Func<XLCellValue>? Total, string? Format)>
        {
            ("", "#", (_, i) => i, () => "Total", null),
            ("", "Container ref.", (x, _) => x.ContainerRef, null, null),
            ("", "Container number", (x, _) => x.ContainerNo ?? "", null, null),
            ("", "Items", (x, _) => x.Items ?? "", null, null),
            ("", "Final destination", (x, _) => x.FinalDestination ?? "", null, null),
            ("", "Current location", (x, _) => x.StageLabel, null, null),
            ("", "Dispatched", (x, _) => x.DispatchDate is { } d ? d.ToDateTime(TimeOnly.MinValue) : "", null, "dd/mm/yyyy"),
            ("", "Offloaded", (x, _) => x.OffloadedDate is { } o ? o.ToDateTime(TimeOnly.MinValue) : "", null, "dd/mm/yyyy"),
        };
        foreach (var type in report.ChargeTypes)
        {
            var id = type.Id;
            var totals = report.Totals.PerType[id];
            columns.Add((type.ChargeName, "Status", (x, _) => x.Charges[id].Status + (x.Charges[id].Count > 1 ? $" ({x.Charges[id].Count})" : ""),
                () => $"{totals.Missing} missing", null));
            columns.Add((type.ChargeName, "Amount", (x, _) => x.Charges[id].Amount is { } a ? a : "", () => totals.Amount, amountFormat));
            if (sees)
            {
                columns.Add((type.ChargeName, "Paid", (x, _) => x.Charges[id].Paid is { } p && x.Charges[id].Status != "Missing" ? p : "",
                    () => totals.Paid ?? 0, amountFormat));
                columns.Add((type.ChargeName, "Payment", (x, _) => StatusText(x.Charges[id].PaymentStatus), null, null));
            }
        }

        if (report.ChargeTypes.Count > 1)
        {
            columns.Add(("All charges", "Amount", (x, _) => x.Amount, () => report.Totals.Amount, amountFormat));
            if (sees)
            {
                columns.Add(("All charges", "Paid", (x, _) => x.Paid ?? 0, () => report.Totals.Paid ?? 0, amountFormat));
                columns.Add(("All charges", "Balance", (x, _) => x.Balance ?? 0, () => report.Totals.Balance ?? 0, amountFormat));
            }
        }

        var top = r;
        for (var c = 0; c < columns.Count; c++)
        {
            sheet.Cell(top, c + 1).Value = columns[c].Group;
            sheet.Cell(top + 1, c + 1).Value = columns[c].Header;
        }

        for (var c = 0; c < columns.Count;)
        {
            var end = c;
            while (end + 1 < columns.Count && columns[end + 1].Group == columns[c].Group && columns[c].Group != "") end++;
            if (end > c) sheet.Range(top, c + 1, top, end + 1).Merge();
            c = end + 1;
        }

        var header = sheet.Range(top, 1, top + 1, columns.Count);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromArgb(0x1F, 0x4E, 0x79);
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        header.Style.Alignment.WrapText = true;
        r = top + 2;

        // Grouped by current location, in the Container Report's order of the stages.
        var n = 0;
        foreach (var group in report.Rows.GroupBy(x => (x.StageSort, x.StageLabel)).OrderBy(g => g.Key.StageSort).ThenBy(g => g.Key.StageLabel))
        {
            sheet.Cell(r, 1).Value = $"{group.Key.StageLabel} · {group.Count()} containers · {group.Sum(x => x.Amount):N2}";
            var band = sheet.Range(r, 1, r, columns.Count);
            band.Style.Font.Bold = true;
            band.Style.Fill.BackgroundColor = XLColor.FromArgb(0xDD, 0xEB, 0xF7);
            r++;

            foreach (var row in group)
            {
                n++;
                for (var c = 0; c < columns.Count; c++)
                {
                    var cell = sheet.Cell(r, c + 1);
                    cell.Value = columns[c].Row(row, n);
                    if (columns[c].Format is { } format) cell.Style.NumberFormat.Format = format;
                }

                if (row.Charges.Values.Any(x => x.Status == "Missing"))
                {
                    sheet.Range(r, 1, r, columns.Count).Style.Fill.BackgroundColor = XLColor.FromArgb(0xFD, 0xE2, 0xE2);
                }

                r++;
            }
        }

        for (var c = 0; c < columns.Count; c++)
        {
            if (columns[c].Total is not { } total) continue;
            var cell = sheet.Cell(r, c + 1);
            cell.Value = total();
            if (columns[c].Format is { } format) cell.Style.NumberFormat.Format = format;
        }

        var totalRow = sheet.Range(r, 1, r, columns.Count);
        totalRow.Style.Font.Bold = true;
        totalRow.Style.Border.TopBorder = XLBorderStyleValues.Thin;
        r += 2;

        if (report.Rows.Count == 0)
        {
            sheet.Cell(r++, 1).Value = "No containers for the selected criteria.";
        }
        else if (report.Totals.WithMissing > 0)
        {
            sheet.Cell(r++, 1).Value = $"{report.Totals.WithMissing} container(s) with a charge missing (highlighted in red).";
        }

        sheet.SheetView.FreezeRows(top + 1);
        sheet.Columns(1, columns.Count).AdjustToContents(top, r);
        sheet.Column(4).Width = Math.Min(sheet.Column(4).Width, 40);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
