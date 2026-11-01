using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Security;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Reports › Item Balance Report (script 103): each item in each warehouse - the opening on Date From, one quantity and
/// amount per kind of movement in the period, the closing on Date To - for month-end.
///
/// THE SYSTEM'S AVERAGE, REPLAYED HERE. The database gives every event of the items oldest first (stock movements and
/// cost adjustments, cancelled documents left out); this class replays the company's weighted average exactly as
/// inventory.usp_Item_RebuildCosts does (a receipt at its cost, everything that leaves and both legs of a transfer at the
/// average, a cost adjustment spread over the stock on hand, the average kept while the stock is at or below zero, rounded
/// to six places as the column holds it). A movement is worth its quantity at that value; the opening and the closing are
/// the warehouse's quantity at the average of that moment, so the closings add up to Stock Valuation; the rest is the
/// row's Average cost change, so every row adds up.
///
/// THE CURRENCY (period-end translation): the opening at the rate of Date From − 1, each movement at the rate of its day,
/// the closing and the average cost change at the rate of Date To; what is left is the translation difference.
///
/// THE SERVER STRIPS, THE PAGE HIDES: without View item costs every amount is null and no rate is read.
/// </summary>
public sealed class ItemBalanceReportService : IItemBalanceReportService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string ValidationCode = "VALIDATION";
    private const string AdjustmentGroup = "ADJ";

    private sealed record GroupDef(string Code, string Label, string Direction);

    /// <summary>The kinds of movement, in the order of the columns. Codes the database sends that are not here get a column after them.</summary>
    private static readonly GroupDef[] Catalogue =
    [
        // Goods receipts, and the receipts of before them (a container offload, a local invoice): script 103 files those as GRN+.
        new("GRN+", "Purchase receipt", "In"),
        new("PRET-", "Purchase return", "Out"),
        new("SINV-", "Sales delivery", "Out"),
        new("SRET+", "Sales return", "In"),
        new("TRF+", "Transfer in", "In"),
        new("TRF-", "Transfer out", "Out"),
        new("TRF_LOSS", "Transfer loss", "Out"),
        new("INV_IN+", "Inventory In", "In"),
        new("INV_OUT-", "Inventory Out", "Out"),
        new("BIV_OUT-", "BIVAC Out", "Out"),
        new(AdjustmentGroup, "Cost adjustments", "Value"),
    ];

    private static readonly Dictionary<byte, string> RateTypeNames = new() { [1] = "Official", [2] = "Non-official", [3] = "Market" };

    private static readonly CultureInfo Numbers = CultureInfo.GetCultureInfo("en-US");

    private readonly IItemBalanceReportRepository _reports;
    private readonly TimeProvider _clock;

    public ItemBalanceReportService(IItemBalanceReportRepository reports, TimeProvider clock)
    {
        _reports = reports;
        _clock = clock;
    }

    public async Task<Result<IReadOnlyList<ItemBalanceWarehouseDto>>> WarehousesAsync(
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Reports.ItemBalanceView))
        {
            return Forbidden<IReadOnlyList<ItemBalanceWarehouseDto>>();
        }

        return Result<IReadOnlyList<ItemBalanceWarehouseDto>>.Success(await _reports.WarehousesAsync(userId, cancellationToken));
    }

    public async Task<Result<ItemBalanceReportResult>> ReportAsync(
        ItemBalanceReportQuery query, string output, int userId, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var watch = Stopwatch.StartNew();
        var built = await BuildAsync(query, userId, userName, permissions, cancellationToken);
        if (!built.IsSuccess)
        {
            return built;
        }

        await LogAsync(query, built.Value!, output, userId, watch, cancellationToken);
        return built;
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ItemBalanceReportQuery query, int userId, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var watch = Stopwatch.StartNew();
        var built = await BuildAsync(query, userId, userName, permissions, cancellationToken);
        if (!built.IsSuccess)
        {
            return Result<(byte[], string)>.Failure(built.ErrorType, built.Error!, built.Code ?? ValidationCode);
        }

        var report = built.Value!;
        var content = BuildWorkbook(report, query.HideEmptyColumns);
        await LogAsync(query, report, "Excel", userId, watch, cancellationToken);
        return Result<(byte[], string)>.Success(
            (content, $"ItemBalance_{report.DateFrom:yyyyMMdd}-{report.DateTo:yyyyMMdd}.xlsx"));
    }

    public async Task<Result<ItemBalanceMovementsResult>> MovementsAsync(
        ItemBalanceMovementsQuery query, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Reports.ItemBalanceView))
        {
            return Forbidden<ItemBalanceMovementsResult>();
        }

        if (Dates(query.DateFrom, query.DateTo) is { } dateError)
        {
            return Result<ItemBalanceMovementsResult>.Failure(ErrorType.Validation, dateError, ValidationCode);
        }

        var from = query.DateFrom!.Value;
        var to = query.DateTo!.Value;
        var sees = ItemCosts.Sees(permissions);
        RateTable? rates = null;
        if (sees)
        {
            var loaded = await LoadRatesAsync(query.CurrencyId, query.RateType, from, to, cancellationToken);
            if (!loaded.IsSuccess)
            {
                return Result<ItemBalanceMovementsResult>.Failure(loaded.ErrorType, loaded.Error!, loaded.Code ?? ValidationCode);
            }

            rates = loaded.Value;
        }

        ItemBalanceData data;
        try
        {
            data = await _reports.DataAsync(userId, [query.WarehouseId], [query.ItemId], [], from, to, detail: true, cancellationToken);
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.WarehouseAccessDenied)
        {
            return WarehouseAccess.Failure<ItemBalanceMovementsResult>(ex.Message);
        }

        var group = string.IsNullOrWhiteSpace(query.Group) ? null : query.Group.Trim();
        var movements = new List<ItemBalanceMovementDto>();
        Replay(data.Events, (e, value) =>
        {
            if (!e.InPeriod || e.WarehouseId != query.WarehouseId || (group is not null && e.GroupCode != group))
            {
                return;
            }

            var rate = rates?.At(DateOnly.FromDateTime(e.EventDate)).Rate ?? 1m;
            movements.Add(new ItemBalanceMovementDto
            {
                EventAt = e.EventAt ?? e.EventDate,
                GroupCode = e.GroupCode,
                GroupLabel = GroupOf(e.GroupCode).Label,
                DocumentTypeCode = e.DocumentTypeCode,
                DocumentId = e.DocumentId,
                DocumentNumber = e.DocumentNumber,
                TransferOrderId = e.TransferOrderId,
                Quantity = e.Qty,
                UnitCost = sees && e.Qty != 0 ? value / e.Qty * rate : null,
                Amount = sees ? value * rate : null,
            });
        });

        var item = data.Items.FirstOrDefault(i => i.ItemId == query.ItemId);
        var warehouse = data.Warehouses.FirstOrDefault(w => w.WarehouseId == query.WarehouseId);
        return Result<ItemBalanceMovementsResult>.Success(new ItemBalanceMovementsResult
        {
            ItemCode = item?.ItemCode ?? string.Empty,
            ItemName = item?.ItemName ?? string.Empty,
            WarehouseCode = warehouse?.WarehouseCode ?? string.Empty,
            WarehouseName = warehouse?.WarehouseName ?? string.Empty,
            CurrencyCode = rates?.Currency.CurrencyCode,
            Movements = movements,
        });
    }

    /* ── The report ────────────────────────────────────────────────────────────────────────────── */

    private async Task<Result<ItemBalanceReportResult>> BuildAsync(
        ItemBalanceReportQuery query, int userId, string userName, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        if (!permissions.Contains(Permissions.Reports.ItemBalanceView))
        {
            return Forbidden<ItemBalanceReportResult>();
        }

        if (Dates(query.DateFrom, query.DateTo) is { } dateError)
        {
            return Result<ItemBalanceReportResult>.Failure(ErrorType.Validation, dateError, ValidationCode);
        }

        var from = query.DateFrom!.Value;
        var to = query.DateTo!.Value;
        var sees = ItemCosts.Sees(permissions);
        RateTable? rates = null;
        if (sees)
        {
            var loaded = await LoadRatesAsync(query.CurrencyId, query.RateType, from, to, cancellationToken);
            if (!loaded.IsSuccess)
            {
                return Result<ItemBalanceReportResult>.Failure(loaded.ErrorType, loaded.Error!, loaded.Code ?? ValidationCode);
            }

            rates = loaded.Value;
        }

        var warehouseIds = (query.WarehouseIds ?? []).Where(id => id > 0).Distinct().ToList();
        var itemIds = (query.ItemIds ?? []).Where(id => id > 0).Distinct().ToList();
        var familyIds = (query.FamilyIds ?? []).Where(id => id > 0).Distinct().ToList();

        ItemBalanceData data;
        try
        {
            data = await _reports.DataAsync(userId, warehouseIds, itemIds, familyIds, from, to, detail: false, cancellationToken);
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.WarehouseAccessDenied)
        {
            return WarehouseAccess.Failure<ItemBalanceReportResult>(ex.Message);
        }

        var offered = warehouseIds.Count == 0 ? [] : await _reports.WarehousesAsync(userId, cancellationToken);
        var report = Compute(data, rates, from, to, sees, query.ShowZeroBalance);

        return Result<ItemBalanceReportResult>.Success(new ItemBalanceReportResult
        {
            DateFrom = from,
            DateTo = to,
            SeesAmounts = sees,
            Currency = rates?.Currency,
            RateType = rates?.RateType,
            RateTypeName = rates is null ? null : RateTypeNames.GetValueOrDefault(rates.RateType, $"Type {rates.RateType}"),
            OpeningRate = rates is null ? null : Rate(rates, from.AddDays(-1)),
            ClosingRate = rates is null ? null : Rate(rates, to),
            WarehousesLabel = warehouseIds.Count == 0
                ? "All my warehouses"
                : string.Join(", ", warehouseIds.Select(id => offered.FirstOrDefault(w => w.Id == id) is { } w
                    ? $"{w.WarehouseCode} {w.WarehouseName}" : $"#{id}")),
            ItemsLabel = itemIds.Count == 0 && familyIds.Count == 0
                ? null
                : string.Join(", ", new[]
                {
                    itemIds.Count == 0 ? null : $"{itemIds.Count} item{(itemIds.Count == 1 ? "" : "s")}",
                    familyIds.Count == 0 ? null : $"{familyIds.Count} famil{(familyIds.Count == 1 ? "y" : "ies")}",
                }.Where(x => x is not null)),
            Groups = report.Groups,
            Rows = report.Rows,
            Totals = report.Totals,
            IntegrityFailures = report.Rows.Count(r => !r.IntegrityOk),
            NegativeRows = report.Rows.Count(r => r.IsNegative),
            RoundingNotes = RoundingNotes(report.Rows, report.Totals, report.Groups, rates?.Currency.DecimalPlaces ?? 2, sees),
            GeneratedAtUtc = _clock.GetUtcNow(),
            GeneratedBy = userName,
        });
    }

    private sealed class CellAcc
    {
        public long Qty;
        public decimal Base;
        public decimal Amount;
    }

    private sealed class RowAcc
    {
        public long OpeningQty;
        public readonly Dictionary<string, CellAcc> Cells = [];
    }

    private static (List<ItemBalanceGroupDto> Groups, List<ItemBalanceRowDto> Rows, ItemBalanceTotalsDto Totals) Compute(
        ItemBalanceData data, RateTable? rates, DateOnly from, DateOnly to, bool sees, bool showZero)
    {
        var accs = new Dictionary<(int Item, int Warehouse), RowAcc>();
        RowAcc AccOf(int item, int warehouse)
        {
            if (!accs.TryGetValue((item, warehouse), out var acc))
            {
                accs[(item, warehouse)] = acc = new RowAcc();
            }

            return acc;
        }

        var averages = Replay(data.Events, (e, value) =>
        {
            if (!e.InScope)
            {
                return;
            }

            var acc = AccOf(e.ItemId, e.WarehouseId);
            if (!e.InPeriod)
            {
                acc.OpeningQty += e.Qty;
                return;
            }

            if (!acc.Cells.TryGetValue(e.GroupCode, out var cell))
            {
                acc.Cells[e.GroupCode] = cell = new CellAcc();
            }

            cell.Qty += e.Qty;
            cell.Base += value;
            cell.Amount += value * (rates?.At(DateOnly.FromDateTime(e.EventDate)).Rate ?? 1m);
        });

        // A ledger quantity with no event left (every one of its documents cancelled, or a lone reversal) still gets its
        // row, so the integrity check sees it.
        var ledger = data.Ledger.ToDictionary(l => (l.ItemId, l.WarehouseId), l => l.QuantityBase);
        foreach (var key in ledger.Keys)
        {
            AccOf(key.ItemId, key.WarehouseId);
        }

        var items = data.Items.ToDictionary(i => i.ItemId);
        var warehouses = data.Warehouses.ToDictionary(w => w.WarehouseId);
        var openRate = rates?.At(from.AddDays(-1)).Rate ?? 1m;
        var closeRate = rates?.At(to).Rate ?? 1m;
        var translated = rates is { Currency.IsBaseCurrency: false };

        var rows = new List<ItemBalanceRowDto>();
        foreach (var ((itemId, warehouseId), acc) in accs)
        {
            var (avgStart, avgEnd) = averages.GetValueOrDefault(itemId);
            var closingQty = acc.OpeningQty + acc.Cells.Values.Sum(c => c.Qty);
            var openBase = acc.OpeningQty * avgStart;
            var closeBase = closingQty * avgEnd;
            var changeBase = closeBase - openBase - acc.Cells.Values.Sum(c => c.Base);
            var openAmount = openBase * openRate;
            var closeAmount = closeBase * closeRate;
            var changeAmount = changeBase * closeRate;
            var translation = closeAmount - openAmount - acc.Cells.Values.Sum(c => c.Amount) - changeAmount;

            if (!showZero && acc.OpeningQty == 0 && closingQty == 0 && Math.Round(closeAmount, 2) == 0
                && acc.Cells.Values.All(c => c.Qty == 0 && Math.Round(c.Amount, 2) == 0))
            {
                continue;
            }

            items.TryGetValue(itemId, out var item);
            warehouses.TryGetValue(warehouseId, out var warehouse);
            var isTop = warehouse is null || warehouse.RootId == warehouse.WarehouseId;
            var ledgerQty = ledger.GetValueOrDefault((itemId, warehouseId));
            var row = new ItemBalanceRowDto
            {
                ItemId = itemId,
                ItemCode = item?.ItemCode ?? $"#{itemId}",
                ItemName = item?.ItemName ?? string.Empty,
                Unit = item?.Unit,
                FamilyName = item?.FamilyName,
                WarehouseId = warehouseId,
                WarehouseCode = isTop ? warehouse?.WarehouseCode ?? $"#{warehouseId}" : warehouse!.RootCode,
                WarehouseName = isTop ? warehouse?.WarehouseName ?? string.Empty : warehouse!.RootName,
                LocationCode = isTop ? null : warehouse!.WarehouseCode,
                LocationName = isTop ? null : warehouse!.WarehouseName,
                IsTransit = warehouse?.IsTransit ?? false,
                OpeningQuantity = acc.OpeningQty,
                OpeningAmount = sees ? openAmount : null,
                ClosingQuantity = closingQty,
                ClosingAmount = sees ? closeAmount : null,
                UnitCost = sees && closingQty != 0 ? closeAmount / closingQty : null,
                AverageCostChange = sees ? changeAmount : null,
                TranslationDifference = sees && translated ? translation : null,
                IsNegative = closingQty < 0 || acc.OpeningQty < 0,
                LedgerQuantity = ledgerQty,
                IntegrityOk = ledgerQty == closingQty,
            };

            foreach (var (code, cell) in acc.Cells)
            {
                row.Movements[code] = new ItemBalanceCellDto { Quantity = cell.Qty, Amount = sees ? cell.Amount : null };
                switch (GroupOf(code).Direction)
                {
                    case "In":
                        row.TotalInQuantity += cell.Qty;
                        row.TotalInAmount = sees ? (row.TotalInAmount ?? 0) + cell.Amount : null;
                        break;
                    case "Out":
                        row.TotalOutQuantity += cell.Qty;
                        row.TotalOutAmount = sees ? (row.TotalOutAmount ?? 0) + cell.Amount : null;
                        break;
                }
            }

            if (sees)
            {
                row.TotalInAmount ??= 0;
                row.TotalOutAmount ??= 0;
            }

            rows.Add(row);
        }

        rows.Sort((a, b) =>
        {
            var c = string.Compare(a.ItemCode, b.ItemCode, StringComparison.OrdinalIgnoreCase);
            if (c != 0) return c;
            c = string.Compare(a.WarehouseCode, b.WarehouseCode, StringComparison.OrdinalIgnoreCase);
            return c != 0 ? c : string.Compare(a.LocationCode ?? "", b.LocationCode ?? "", StringComparison.OrdinalIgnoreCase);
        });

        var active = rows.SelectMany(r => r.Movements).Where(m => m.Value.Quantity != 0 || (m.Value.Amount ?? 0) != 0)
            .Select(m => m.Key).ToHashSet();
        var groups = Catalogue.Select(g => new ItemBalanceGroupDto { Code = g.Code, Label = g.Label, Direction = g.Direction }).ToList();
        groups.AddRange(rows.SelectMany(r => r.Movements.Keys).Distinct()
            .Where(code => Catalogue.All(g => g.Code != code)).Order()
            .Select(code => GroupOf(code)).Select(g => new ItemBalanceGroupDto { Code = g.Code, Label = g.Label, Direction = g.Direction }));
        foreach (var group in groups)
        {
            group.HasActivity = active.Contains(group.Code);
        }

        var totals = new ItemBalanceTotalsDto
        {
            OpeningQuantity = rows.Sum(r => r.OpeningQuantity),
            OpeningAmount = SumOrNull(rows, r => r.OpeningAmount, sees),
            TotalInQuantity = rows.Sum(r => r.TotalInQuantity),
            TotalInAmount = SumOrNull(rows, r => r.TotalInAmount, sees),
            TotalOutQuantity = rows.Sum(r => r.TotalOutQuantity),
            TotalOutAmount = SumOrNull(rows, r => r.TotalOutAmount, sees),
            AverageCostChange = SumOrNull(rows, r => r.AverageCostChange, sees),
            ClosingQuantity = rows.Sum(r => r.ClosingQuantity),
            ClosingAmount = SumOrNull(rows, r => r.ClosingAmount, sees),
            TranslationDifference = SumOrNull(rows, r => r.TranslationDifference, sees && translated),
        };
        foreach (var group in groups)
        {
            var cells = rows.Select(r => r.Movements.GetValueOrDefault(group.Code)).Where(c => c is not null).ToList();
            if (cells.Count > 0)
            {
                totals.Movements[group.Code] = new ItemBalanceCellDto
                {
                    Quantity = cells.Sum(c => c!.Quantity),
                    Amount = sees ? cells.Sum(c => c!.Amount ?? 0) : null,
                };
            }
        }

        return (groups, rows, totals);
    }

    /// <summary>
    /// THE COMPANY'S AVERAGE, AS inventory.usp_Item_RebuildCosts REPLAYS IT. Calls <paramref name="onEvent"/> with each event
    /// and what it is worth in the base currency (a receipt at its cost, an issue or a transfer at the average, a cost
    /// adjustment at its amount), and answers each item's average when the period starts and when it ends.
    /// </summary>
    private static Dictionary<int, (decimal Start, decimal End)> Replay(
        IReadOnlyList<ItemBalanceEventRow> events, Action<ItemBalanceEventRow, decimal> onEvent)
    {
        var averages = new Dictionary<int, (decimal, decimal)>();
        var i = 0;
        while (i < events.Count)
        {
            var itemId = events[i].ItemId;
            decimal onHand = 0, average = 0;
            decimal? start = null;
            for (; i < events.Count && events[i].ItemId == itemId; i++)
            {
                var e = events[i];
                if (e.InPeriod && start is null)
                {
                    start = average;
                }

                decimal value;
                if (e.Amount is { } adjustment)
                {
                    value = adjustment;
                    if (onHand > 0)
                    {
                        average = Math.Round(average + adjustment / onHand, 6);
                    }
                }
                else if (e.Qty > 0)
                {
                    var cost = e.Cost ?? average;
                    value = e.Qty * cost;
                    if (onHand + e.Qty > 0)
                    {
                        // At or below zero the stock held counts as none: the receipt that brings it back sets the average.
                        var held = Math.Max(onHand, 0);
                        average = Math.Round((held * average + e.Qty * cost) / (held + e.Qty), 6);
                    }

                    onHand += e.Qty;
                }
                else
                {
                    value = e.Qty * average;
                    onHand += e.Qty;
                }

                onEvent(e, value);
            }

            averages[itemId] = (start ?? average, average);
        }

        return averages;
    }

    private static GroupDef GroupOf(string code)
    {
        if (Catalogue.FirstOrDefault(g => g.Code == code) is { } known)
        {
            return known;
        }

        var inward = code.EndsWith('+');
        var type = code.TrimEnd('+', '-');
        return new GroupDef(code, $"{type} {(inward ? "in" : "out")}", inward ? "In" : "Out");
    }

    private static decimal? SumOrNull(IEnumerable<ItemBalanceRowDto> rows, Func<ItemBalanceRowDto, decimal?> pick, bool sees)
        => sees ? rows.Sum(r => pick(r) ?? 0) : null;

    /// <summary>
    /// ROUNDING IS FOR THE EYE: the totals are sums of the unrounded values, so the rounded rows may differ from the rounded
    /// total by a cent. Each column where they do is named.
    /// </summary>
    private static List<string> RoundingNotes(
        IReadOnlyList<ItemBalanceRowDto> rows, ItemBalanceTotalsDto totals, IReadOnlyList<ItemBalanceGroupDto> groups, int decimals, bool sees)
    {
        var notes = new List<string>();
        if (!sees)
        {
            return notes;
        }

        void Check(string label, Func<ItemBalanceRowDto, decimal?> pick, decimal? total)
        {
            if (total is null) return;
            var shown = rows.Sum(r => Math.Round(pick(r) ?? 0, decimals, MidpointRounding.AwayFromZero));
            var rounded = Math.Round(total.Value, decimals, MidpointRounding.AwayFromZero);
            if (shown != rounded)
            {
                notes.Add($"{label}: the rows add up to {shown.ToString($"N{decimals}", Numbers)}, the total is {rounded.ToString($"N{decimals}", Numbers)} (rounding).");
            }
        }

        Check("Opening amount", r => r.OpeningAmount, totals.OpeningAmount);
        foreach (var group in groups)
        {
            if (totals.Movements.TryGetValue(group.Code, out var cell))
            {
                Check(group.Label, r => r.Movements.GetValueOrDefault(group.Code)?.Amount, cell.Amount);
            }
        }

        Check("Total in", r => r.TotalInAmount, totals.TotalInAmount);
        Check("Total out", r => r.TotalOutAmount, totals.TotalOutAmount);
        Check("Average cost change", r => r.AverageCostChange, totals.AverageCostChange);
        Check("Translation difference", r => r.TranslationDifference, totals.TranslationDifference);
        Check("Closing amount", r => r.ClosingAmount, totals.ClosingAmount);
        return notes;
    }

    /* ── Currency ──────────────────────────────────────────────────────────────────────────────── */

    private sealed class RateTable
    {
        public required ItemBalanceCurrencyDto Currency { get; init; }
        public required byte RateType { get; init; }
        public required DateOnly[] Dates { get; init; }
        public required decimal[] Rates { get; init; }

        /// <summary>The rate in force on a day (the latest on or before it); the base currency is 1.</summary>
        public (DateOnly? Date, decimal Rate) At(DateOnly day)
        {
            if (Currency.IsBaseCurrency)
            {
                return (null, 1m);
            }

            var index = Array.BinarySearch(Dates, day);
            if (index < 0)
            {
                index = ~index - 1;
            }

            return index < 0 ? (null, 0m) : (Dates[index], Rates[index]);
        }
    }

    private static ItemBalanceRateDto Rate(RateTable rates, DateOnly asOf)
    {
        var (date, rate) = rates.At(asOf);
        return new ItemBalanceRateDto { AsOf = asOf, RateDate = date, Rate = rate };
    }

    private async Task<Result<RateTable>> LoadRatesAsync(
        int? currencyId, byte? rateType, DateOnly from, DateOnly to, CancellationToken cancellationToken)
    {
        var type = rateType ?? 1;
        if (!RateTypeNames.ContainsKey(type))
        {
            return Result<RateTable>.Failure(ErrorType.Validation, "Choose the rate type: Official, Non-official or Market.", ValidationCode);
        }

        var id = currencyId ?? await _reports.BaseCurrencyIdAsync(cancellationToken);
        if (id is null)
        {
            return Result<RateTable>.Failure(ErrorType.Validation, "Choose the currency.", ValidationCode);
        }

        var (currency, rows) = await _reports.RatesAsync(id.Value, type, to, cancellationToken);
        if (currency is null)
        {
            return Result<RateTable>.Failure(ErrorType.Validation, "The currency was not found.", ValidationCode);
        }

        var table = new RateTable
        {
            Currency = currency,
            RateType = type,
            Dates = rows.Select(r => DateOnly.FromDateTime(r.RateDate)).ToArray(),
            Rates = rows.Select(r => r.Rate).ToArray(),
        };

        // The opening's rate (Date From − 1) is the earliest the report reads: with it, every later day has one too.
        var openingDay = from.AddDays(-1);
        if (!currency.IsBaseCurrency && table.At(openingDay).Date is null)
        {
            return Result<RateTable>.Failure(ErrorType.Validation,
                $"No {RateTypeNames[type]} rate for {currency.CurrencyCode} on or before {openingDay:dd/MM/yyyy} (the opening's rate, " +
                "the day before Date From): add one in Master Data › Exchange Rates, or choose another rate type.",
                ValidationCode);
        }

        return Result<RateTable>.Success(table);
    }

    /* ── Shared ────────────────────────────────────────────────────────────────────────────────── */

    private static string? Dates(DateOnly? from, DateOnly? to)
    {
        if (from is null || to is null)
        {
            return "Enter Date From and Date To.";
        }

        return from > to ? "Date From is after Date To." : null;
    }

    private static Result<T> Forbidden<T>()
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {Permissions.Reports.ItemBalanceView} permission.", ForbiddenCode);

    private async Task LogAsync(
        ItemBalanceReportQuery query, ItemBalanceReportResult report, string output, int userId, Stopwatch watch,
        CancellationToken cancellationToken)
    {
        var criteria = JsonSerializer.Serialize(query);
        await _reports.LogRunAsync(userId, output, report.DateFrom, report.DateTo, report.Currency?.Id, report.RateType,
            criteria, report.Rows.Count, (int)Math.Min(int.MaxValue, watch.ElapsedMilliseconds), cancellationToken);
    }

    /* ── Excel ─────────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// THE SCREEN, AS A SHEET: the same rows, columns (the movement columns with activity when "Hide empty transaction
    /// columns" is on) and totals, under a header that says the warehouses, the dates, the currency, the rate dates, when
    /// and by whom it was run. Values are written unrounded with a number format, so Excel's own sums match the totals.
    /// </summary>
    private static byte[] BuildWorkbook(ItemBalanceReportResult report, bool hideEmpty)
    {
        var sees = report.SeesAmounts;
        var decimals = report.Currency?.DecimalPlaces ?? 2;
        var amountFormat = decimals == 0 ? "#,##0;[Red]-#,##0" : $"#,##0.{new string('0', decimals)};[Red]-#,##0.{new string('0', decimals)}";
        const string qtyFormat = "#,##0;[Red]-#,##0";
        // As the screen: the column only when some row has a translation difference.
        var translated = sees && report.Currency is { IsBaseCurrency: false }
            && report.Rows.Any(x => x.TranslationDifference is { } t && Math.Abs(t) >= 0.005m);
        var groups = report.Groups.Where(g => !hideEmpty || g.HasActivity).ToList();

        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Item balance");

        var r = 1;
        sheet.Cell(r, 1).Value = "Item Balance Report by Warehouse";
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

        Info("Warehouses", report.WarehousesLabel);
        Info("Period", $"{report.DateFrom:dd/MM/yyyy} to {report.DateTo:dd/MM/yyyy}");
        if (report.ItemsLabel is not null) Info("Items", report.ItemsLabel);
        if (sees && report.Currency is { } currency)
        {
            Info("Currency", $"{currency.CurrencyCode} ({report.RateTypeName} rate)");
            if (!currency.IsBaseCurrency)
            {
                Info("Opening rate", RateText(report.OpeningRate));
                Info("Movements", "at the rate of each movement's day");
                Info("Closing rate", RateText(report.ClosingRate));
            }
        }
        else
        {
            Info("Amounts", "not shown: they need the View item costs permission");
        }

        Info("Run", $"{report.GeneratedAtUtc:dd/MM/yyyy HH:mm} UTC by {report.GeneratedBy}");
        r++;

        // The columns: (header group, sub header, value of a row, value of the totals, format)
        var columns = new List<(string Group, string Header, Func<ItemBalanceRowDto, XLCellValue> Row, Func<XLCellValue>? Total, string? Format)>
        {
            ("", "Item code", x => x.ItemCode, () => "Total", null),
            ("", "Item name", x => x.ItemName, null, null),
            ("", "UoM", x => x.Unit ?? "", null, null),
            ("", "Warehouse", x => $"{x.WarehouseCode} {x.WarehouseName}", null, null),
            ("", "Location", x => x.LocationCode is null ? "" : $"{x.LocationCode} {x.LocationName}", null, null),
            ("Opening", "Qty", x => x.OpeningQuantity, () => report.Totals.OpeningQuantity, qtyFormat),
        };
        if (sees) columns.Add(("Opening", "Amount", x => x.OpeningAmount ?? 0, () => report.Totals.OpeningAmount ?? 0, amountFormat));
        foreach (var g in groups)
        {
            var code = g.Code;
            if (g.Direction != "Value")
            {
                columns.Add((g.Label, "Qty", x => x.Movements.GetValueOrDefault(code)?.Quantity ?? 0,
                    () => report.Totals.Movements.GetValueOrDefault(code)?.Quantity ?? 0, qtyFormat));
            }

            if (sees)
            {
                columns.Add((g.Label, "Amount", x => x.Movements.GetValueOrDefault(code)?.Amount ?? 0,
                    () => report.Totals.Movements.GetValueOrDefault(code)?.Amount ?? 0, amountFormat));
            }
        }

        columns.Add(("Total in", "Qty", x => x.TotalInQuantity, () => report.Totals.TotalInQuantity, qtyFormat));
        if (sees) columns.Add(("Total in", "Amount", x => x.TotalInAmount ?? 0, () => report.Totals.TotalInAmount ?? 0, amountFormat));
        columns.Add(("Total out", "Qty", x => x.TotalOutQuantity, () => report.Totals.TotalOutQuantity, qtyFormat));
        if (sees)
        {
            columns.Add(("Total out", "Amount", x => x.TotalOutAmount ?? 0, () => report.Totals.TotalOutAmount ?? 0, amountFormat));
            columns.Add(("Average cost change", "Amount", x => x.AverageCostChange ?? 0, () => report.Totals.AverageCostChange ?? 0, amountFormat));
        }

        if (translated)
        {
            columns.Add(("Translation difference", "Amount", x => x.TranslationDifference ?? 0, () => report.Totals.TranslationDifference ?? 0, amountFormat));
        }

        columns.Add(("Closing", "Qty", x => x.ClosingQuantity, () => report.Totals.ClosingQuantity, qtyFormat));
        if (sees)
        {
            columns.Add(("Closing", "Amount", x => x.ClosingAmount ?? 0, () => report.Totals.ClosingAmount ?? 0, amountFormat));
            columns.Add(("Closing", "Unit cost", x => x.UnitCost is { } u ? u : "", null, amountFormat));
        }

        columns.Add(("", "Check", x => x.IntegrityOk ? (x.IsNegative ? "Negative" : "") : $"Ledger {x.LedgerQuantity}", null, null));

        // Two header rows: the group over its Qty / Amount.
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

        foreach (var row in report.Rows)
        {
            for (var c = 0; c < columns.Count; c++)
            {
                var cell = sheet.Cell(r, c + 1);
                cell.Value = columns[c].Row(row);
                if (columns[c].Format is { } format) cell.Style.NumberFormat.Format = format;
            }

            if (!row.IntegrityOk)
            {
                sheet.Range(r, 1, r, columns.Count).Style.Fill.BackgroundColor = XLColor.FromArgb(0xFF, 0xE5, 0xB4);
            }
            else if (row.IsNegative)
            {
                sheet.Range(r, 1, r, columns.Count).Style.Fill.BackgroundColor = XLColor.FromArgb(0xFD, 0xE2, 0xE2);
            }

            r++;
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
            sheet.Cell(r++, 1).Value = "No data for the selected criteria.";
        }

        sheet.Cell(r++, 1).Value = report.IntegrityFailures == 0
            ? "Integrity check: every row's opening and movements give the ledger's quantity on Date To."
            : $"Integrity check: {report.IntegrityFailures} row(s) do not add up to the ledger's quantity (highlighted).";
        if (report.NegativeRows > 0)
        {
            sheet.Cell(r++, 1).Value = $"{report.NegativeRows} row(s) with negative stock (highlighted in red), included in the totals.";
        }

        foreach (var note in report.RoundingNotes)
        {
            sheet.Cell(r++, 1).Value = note;
        }

        sheet.SheetView.FreezeRows(top + 1);
        sheet.Columns(1, columns.Count).AdjustToContents(top, r);
        sheet.Column(1).Width = Math.Max(sheet.Column(1).Width, 14);
        sheet.Column(2).Width = Math.Min(Math.Max(sheet.Column(2).Width, 20), 40);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string RateText(ItemBalanceRateDto? rate)
        => rate is null ? "" : rate.RateDate is { } d
            ? $"{rate.Rate.ToString("0.######", Numbers)} (in force on {rate.AsOf:dd/MM/yyyy}, entered for {d:dd/MM/yyyy})"
            : "1 (base currency)";
}
