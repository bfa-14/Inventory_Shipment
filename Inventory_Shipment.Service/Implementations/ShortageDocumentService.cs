using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.Shortages;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ShortageDocumentService : IShortageDocumentService
{
    private const string NotFoundMessage = "Shortage document not found.";
    private const string ForbiddenCode = "FORBIDDEN";

    private readonly IShortageDocumentRepository _shortages;
    private readonly IPurchaseDocumentRepository _purchases;
    private readonly TimeProvider _clock;
    private readonly ILogger<ShortageDocumentService> _logger;

    public ShortageDocumentService(
        IShortageDocumentRepository shortages, IPurchaseDocumentRepository purchases, TimeProvider clock,
        ILogger<ShortageDocumentService> logger)
    {
        _shortages = shortages;
        _purchases = purchases;
        _clock = clock;
        _logger = logger;
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<IReadOnlyList<ShortageLiveRowDto>>> CalculateAsync(
        ShortageCalculateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.ShortagesView))
        {
            return Forbidden<IReadOnlyList<ShortageLiveRowDto>>(Permissions.Inventory.ShortagesView);
        }

        try
        {
            var rows = await _shortages.CalculateAsync(query, cancellationToken);
            return Result<IReadOnlyList<ShortageLiveRowDto>>.Success(rows);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ShortageLiveRowDto>>(ex);
        }
    }

    public async Task<Result<PagedResult<ShortageDocumentListDto>>> SearchAsync(
        ShortageDocumentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.ShortagesView))
        {
            return Forbidden<PagedResult<ShortageDocumentListDto>>(Permissions.Inventory.ShortagesView);
        }

        var (items, totalCount) = await _shortages.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ShortageDocumentListDto>>.Success(new PagedResult<ShortageDocumentListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<ShortageDocumentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.ShortagesView))
        {
            return Forbidden<ShortageDocumentDto>(Permissions.Inventory.ShortagesView);
        }

        return await ReadAsync(id, cancellationToken);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ShortageDocumentDto>> SaveDraftAsync(
        int? id, SaveShortageDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.ShortagesCreate))
        {
            return Forbidden<ShortageDocumentDto>(Permissions.Inventory.ShortagesCreate);
        }

        // Said here with the line numbers the page shows: the table type's primary key would refuse
        // the batch too, but with a message about a constraint nobody on the page has heard of.
        var duplicate = request.Lines
            .Select((line, index) => (line.ItemId, LineNo: index + 1))
            .GroupBy(l => l.ItemId)
            .FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            return Result<ShortageDocumentDto>.Failure(
                ErrorType.Validation,
                $"Line {duplicate.Last().LineNo}: the item is already on line {duplicate.First().LineNo}.", "VALIDATION");
        }

        int savedId;
        try
        {
            savedId = await _shortages.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ShortageDocumentDto>(ex);
        }

        _logger.LogInformation("Shortage plan {DocumentId} saved by user {UserId}", savedId, userId);
        return await ReadAsync(savedId, cancellationToken);
    }

    public Task<Result<ShortageDocumentDto>> RecalculateAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Inventory.ShortagesCreate, permissions, userId, "recalculated", cancellationToken,
            () => _shortages.RecalculateAsync(id, ToRowVersion(rowVersion), userId, cancellationToken));

    public Task<Result<ShortageDocumentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Inventory.ShortagesPost, permissions, userId, "posted", cancellationToken,
            () => _shortages.PostAsync(id, ToRowVersion(rowVersion), userId, cancellationToken));

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.ShortagesDelete))
        {
            return Result.Failure(
                ErrorType.Forbidden, $"This action needs the {Permissions.Inventory.ShortagesDelete} permission.", ForbiddenCode);
        }

        try
        {
            await _shortages.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Shortage plan {DocumentId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /// <summary>
    /// THE PERMISSION IS THE ORDER'S. Turning a plan into a purchase order is creating a purchase
    /// order; seeing the plan is checked too, because the new draft copies its lines.
    /// </summary>
    public async Task<Result<PurchaseDocumentDto>> CreatePurchaseOrderAsync(
        int id, CreatePurchaseOrderFromShortageRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.OrdersCreate))
        {
            return Forbidden<PurchaseDocumentDto>(Permissions.Purchase.OrdersCreate);
        }

        if (!permissions.Contains(Permissions.Inventory.ShortagesView))
        {
            return Forbidden<PurchaseDocumentDto>(Permissions.Inventory.ShortagesView);
        }

        int orderId;
        try
        {
            orderId = await _shortages.CreatePurchaseOrderAsync(
                id, request.DocumentDate, request.ExpectedDate, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PurchaseDocumentDto>(ex);
        }

        _logger.LogInformation(
            "Purchase order {OrderId} created from shortage plan {DocumentId} by user {UserId}", orderId, id, userId);

        var order = await _purchases.GetAsync(orderId, cancellationToken);
        return order is null
            ? Result<PurchaseDocumentDto>.Failure(ErrorType.NotFound, "Document not found.", "NOT_FOUND")
            : Result<PurchaseDocumentDto>.Success(order);
    }

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await GetAsync(id, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        return Result<(byte[], string)>.Success((BuildWorkbook(read.Value), $"Shortage_{read.Value.DocumentNumber}.xlsx"));
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportLiveAsync(
        ShortageCalculateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var rows = await CalculateAsync(query, permissions, cancellationToken);
        if (rows.IsFailure || rows.Value is null)
        {
            return Result<(byte[], string)>.Failure(rows.ErrorType, rows.Error ?? string.Empty, rows.Code ?? "ERROR");
        }

        var stamp = _clock.GetUtcNow().ToString("yyyyMMdd");
        return Result<(byte[], string)>.Success((BuildLiveWorkbook(rows.Value, query), $"Shortage_Live_{stamp}.xlsx"));
    }

    /// <summary>The columns the saved lines and the live rows share, in the order of the customer's study.</summary>
    private static readonly string[] FigureColumns =
    [
        "Item Code", "Item Name", "Brand", "Family", "Current Inventory", "Transit Qty", "Outstanding Order Qty",
        "Stock + Transit", "Total Expected Stock", "Expected Monthly Sales", "Lead Time (Month)", "Expected Requirement",
        "Shortage Qty", "Coverage (Months)",
    ];

    /// <summary>
    /// The plan as it would be filed: the header block says which warehouse, supplier and lead time
    /// the figures belong to, every snapshot column follows, and the totals close it. A posted plan
    /// exports what was posted — the workbook reads the stored snapshot like the page does.
    /// </summary>
    private static byte[] BuildWorkbook(ShortageDocumentDto document)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Shortage Plan");

        sheet.Cell(1, 1).Value = $"Shortage Plan {document.DocumentNumber}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var header = new List<(string Label, string Value)>
        {
            ("Shortage No.", document.DocumentNumber),
            ("Description", document.Description),
            ("Status", document.Status),
            ("Date", document.DocumentDate.ToString("dd/MM/yyyy")),
            ("Warehouse", $"{document.WarehouseCode} - {document.WarehouseName}"),
            ("Branch", $"{document.BranchCode} - {document.BranchName}"),
            ("Supplier", $"{document.SupplierCode} - {document.SupplierName}"),
            ("Lead Time (Month)", document.LeadTimeMonths.ToString("0.##")),
            ("Months of history", document.MonthsOfHistory.ToString()),
            ("Created", $"{document.CreatedByName} {document.CreatedAtUtc:dd/MM/yyyy HH:mm} UTC".Trim()),
            ("Last calculated", document.CalculatedAtUtc is { } at ? $"{at:dd/MM/yyyy HH:mm} UTC" : string.Empty),
            ("Notes", document.Notes ?? string.Empty),
        };

        if (document.Status == ShortageDocumentStatus.Posted)
        {
            header.Insert(3, ("Posted", $"{document.PostedByName} {document.PostedAtUtc:dd/MM/yyyy HH:mm} UTC - historical snapshot".Trim()));
        }

        var row = 3;
        foreach (var (label, value) in header)
        {
            sheet.Cell(row, 1).Value = label;
            sheet.Cell(row, 1).Style.Font.Bold = true;
            sheet.Cell(row, 2).Value = value;
            row++;
        }

        row++;
        string[] columns =
        [
            "#", .. FigureColumns,
            "Manual Monthly Sales", "Purchase Unit", "Required Qty", "Required (base)", "PC per Container",
            "Container Requirement", "Min", "Max", "Last Cost", "Notes",
        ];
        WriteColumnHeader(sheet, row, columns);

        var firstLineRow = row + 1;
        foreach (var line in document.Lines)
        {
            row++;
            sheet.Cell(row, 1).Value = line.LineNo;
            WriteFigures(sheet, row, 2, line, line.EffectiveMonthlySales);
            sheet.Cell(row, 16).Value = Num(line.ExpectedMonthlySalesManual);
            sheet.Cell(row, 17).Value = UnitLabel(line);
            sheet.Cell(row, 18).Value = line.RequiredQty;
            sheet.Cell(row, 19).Value = line.RequiredBase;
            sheet.Cell(row, 20).Value = Num(line.PcPerContainer);
            sheet.Cell(row, 21).Value = Num(line.ContainerRequirement);
            sheet.Cell(row, 22).Value = Num(line.MinQuantity);
            sheet.Cell(row, 23).Value = Num(line.MaxQuantity);
            sheet.Cell(row, 24).Value = Num(line.LastCost);
            sheet.Cell(row, 25).Value = line.Notes ?? string.Empty;
        }

        if (document.Lines.Count > 0)
        {
            FormatFigures(sheet, firstLineRow, row, 2);
            sheet.Range(firstLineRow, 16, row, 16).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(firstLineRow, 21, row, 21).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(firstLineRow, 24, row, 24).Style.NumberFormat.Format = "#,##0.00";
        }

        row += 2;
        var totals = new (string Label, XLCellValue Value, string Format)[]
        {
            ("Items", document.TotalLines, "0"),
            ("Total Shortage (base units)", document.TotalShortageBase, "#,##0"),
            ("Total Required (base units)", document.TotalRequiredBase, "#,##0"),
            ("Containers", document.TotalContainers, "#,##0.00"),
            ("Containers (rounded up)", document.ContainersRounded, "0"),
            ("Container utilization %", Num(document.ContainerUtilizationPct), "0.00"),
        };

        foreach (var (label, value, format) in totals)
        {
            sheet.Cell(row, 2).Value = label;
            sheet.Cell(row, 2).Style.Font.Bold = true;
            sheet.Cell(row, 3).Value = value;
            sheet.Cell(row, 3).Style.NumberFormat.Format = format;
            sheet.Cell(row, 3).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
            row++;
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(2).Width = 22;
        sheet.Column(3).Width = 40;
        sheet.Column(25).Width = 30;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static byte[] BuildLiveWorkbook(IReadOnlyList<ShortageLiveRowDto> rows, ShortageCalculateQuery query)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Shortages (live)");

        sheet.Cell(1, 1).Value = "Shortages - live calculation";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;
        sheet.Cell(2, 1).Value =
            $"Lead Time (Month) {query.LeadTimeMonths:0.##} | Months of history {query.MonthsOfHistory} | " +
            (query.OnlyShortages ? "only items short" : "all items");

        var row = 4;
        string[] columns =
        [
            .. FigureColumns,
            "Sold in Period", "Purchase Unit", "Suggested Qty", "PC per Container", "Container Requirement",
            "Min", "Max", "Last Cost", "Supplier",
        ];
        WriteColumnHeader(sheet, row, columns);

        var firstLineRow = row + 1;
        foreach (var r in rows)
        {
            row++;
            WriteFigures(sheet, row, 1, r, r.ExpectedMonthlySalesBase);
            sheet.Cell(row, 15).Value = r.SoldInPeriodBase;
            sheet.Cell(row, 16).Value = UnitLabel(r);
            sheet.Cell(row, 17).Value = r.SuggestedRequiredQty;
            sheet.Cell(row, 18).Value = Num(r.PcPerContainer);
            sheet.Cell(row, 19).Value = Num(r.ContainerRequirement);
            sheet.Cell(row, 20).Value = Num(r.MinQuantity);
            sheet.Cell(row, 21).Value = Num(r.MaxQuantity);
            sheet.Cell(row, 22).Value = Num(r.LastCost);
            sheet.Cell(row, 23).Value = r.SupplierName ?? string.Empty;
        }

        if (rows.Count > 0)
        {
            FormatFigures(sheet, firstLineRow, row, 1);
            sheet.Range(firstLineRow, 19, row, 19).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(firstLineRow, 22, row, 22).Style.NumberFormat.Format = "#,##0.00";
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(2).Width = 40;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static void WriteColumnHeader(IXLWorksheet sheet, int row, string[] columns)
    {
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(row, i + 1).Value = columns[i];
        }

        var range = sheet.Range(row, 1, row, columns.Length);
        range.Style.Font.Bold = true;
        range.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        range.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
    }

    /// <summary>The fourteen <see cref="FigureColumns"/>, starting at <paramref name="column"/>.</summary>
    private static void WriteFigures(IXLWorksheet sheet, int row, int column, ShortageFiguresDto f, decimal monthlySales)
    {
        sheet.Cell(row, column).Value = f.ItemCode;
        sheet.Cell(row, column + 1).Value = f.ItemName;
        sheet.Cell(row, column + 2).Value = f.BrandName;
        sheet.Cell(row, column + 3).Value = f.FamilyName;
        sheet.Cell(row, column + 4).Value = f.CurrentInventoryBase;
        sheet.Cell(row, column + 5).Value = f.TransitBase;
        sheet.Cell(row, column + 6).Value = f.OutstandingOrderBase;
        sheet.Cell(row, column + 7).Value = f.StockPlusTransitBase;
        sheet.Cell(row, column + 8).Value = f.TotalExpectedStockBase;
        sheet.Cell(row, column + 9).Value = monthlySales;
        sheet.Cell(row, column + 10).Value = f.LeadTimeMonths;
        sheet.Cell(row, column + 11).Value = f.ExpectedRequirementBase;
        sheet.Cell(row, column + 12).Value = f.ShortageBase;
        sheet.Cell(row, column + 13).Value = Num(f.CoverageMonths);
    }

    private static void FormatFigures(IXLWorksheet sheet, int firstRow, int lastRow, int column)
    {
        sheet.Range(firstRow, column + 4, lastRow, column + 8).Style.NumberFormat.Format = "#,##0";
        sheet.Range(firstRow, column + 9, lastRow, column + 11).Style.NumberFormat.Format = "#,##0.00";
        sheet.Range(firstRow, column + 12, lastRow, column + 12).Style.NumberFormat.Format = "#,##0";
        sheet.Range(firstRow, column + 13, lastRow, column + 13).Style.NumberFormat.Format = "#,##0.00";
    }

    private static string UnitLabel(ShortageFiguresDto f)
        => f.PurchasePackingFormula > 1 ? $"{f.PurchaseUnitName} (x{f.PurchasePackingFormula})" : f.PurchaseUnitName;

    /// <summary>A blank cell for "no value" — a 0 would read as a measured zero.</summary>
    private static XLCellValue Num(decimal? value) => value is { } v ? v : Blank.Value;

    private static XLCellValue Num(int? value) => value is { } v ? v : Blank.Value;

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private async Task<Result<ShortageDocumentDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var document = await _shortages.GetAsync(id, cancellationToken);
        return document is null
            ? Result<ShortageDocumentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ShortageDocumentDto>.Success(document);
    }

    private async Task<Result<ShortageDocumentDto>> ChangeAsync(
        int id, string permission, IReadOnlySet<string> permissions, int userId, string verb,
        CancellationToken cancellationToken, Func<Task> change)
    {
        if (!permissions.Contains(permission))
        {
            return Forbidden<ShortageDocumentDto>(permission);
        }

        try
        {
            await change();
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ShortageDocumentDto>(ex);
        }

        _logger.LogInformation("Shortage plan {DocumentId} {Verb} by user {UserId}", id, verb, userId);

        // Re-read: a recalculation replaces every figure and the totals, posting stamps who and when.
        return await ReadAsync(id, cancellationToken);
    }

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified. THE MESSAGE IS ALWAYS THE PROCEDURE'S — "Line 2: item X
    /// is inactive." names the line, and only the code is added. The order the plan creates is saved
    /// by the purchase engine, so its 65xxx refusals are classified here too.
    /// </summary>
    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.ShortageDocumentValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.ShortageDocumentConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.ShortageDocumentNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.ShortageDocumentNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.ShortageDocumentNoLines => new RuleFailure(ErrorType.Validation, exception.Message, "NO_LINES"),
        SqlErrors.ShortageDocumentInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.ShortageDocumentNothingToOrder => new RuleFailure(ErrorType.Conflict, exception.Message, "NOTHING_TO_ORDER"),
        SqlErrors.PurchaseDocumentMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),
        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
    };

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }

    private readonly record struct RuleFailure(ErrorType Type, string Message, string Code);
}
