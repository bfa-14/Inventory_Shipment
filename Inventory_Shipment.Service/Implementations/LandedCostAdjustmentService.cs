using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class LandedCostAdjustmentService : ILandedCostAdjustmentService
{
    private const string NotFoundMessage = "Adjustment not found.";
    private const string ForbiddenCode = "FORBIDDEN";

    private readonly ILandedCostAdjustmentRepository _adjustments;
    private readonly ILogger<LandedCostAdjustmentService> _logger;

    public LandedCostAdjustmentService(
        ILandedCostAdjustmentRepository adjustments, ILogger<LandedCostAdjustmentService> logger)
    {
        _adjustments = adjustments;
        _logger = logger;
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<LandedCostAdjustmentListDto>>> SearchAsync(
        LandedCostAdjustmentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsView))
        {
            return Forbidden<PagedResult<LandedCostAdjustmentListDto>>(Permissions.Purchase.LandedCostsView);
        }

        var (items, totalCount) = await _adjustments.SearchAsync(query, cancellationToken);

        return Result<PagedResult<LandedCostAdjustmentListDto>>.Success(new PagedResult<LandedCostAdjustmentListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<LandedCostAdjustmentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => permissions.Contains(Permissions.Purchase.LandedCostsView)
            ? await ReadAsync(id, cancellationToken)
            : Forbidden<LandedCostAdjustmentDto>(Permissions.Purchase.LandedCostsView);

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<LandedCostAdjustmentDto>> SaveDraftAsync(
        int? id, SaveLandedCostAdjustmentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsCreate))
        {
            return Forbidden<LandedCostAdjustmentDto>(Permissions.Purchase.LandedCostsCreate);
        }

        if (request.Charges.Count == 0)
        {
            return Result<LandedCostAdjustmentDto>.Failure(
                ErrorType.Validation, "Add at least one charge before saving.", "VALIDATION");
        }

        // Said here with the numbers the page shows: the table type's primary key would refuse the
        // batch too, but with a message about a constraint nobody on the page has heard of.
        var duplicate = request.Charges.GroupBy(c => c.LineNumber).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            return Result<LandedCostAdjustmentDto>.Failure(
                ErrorType.Validation, $"Charge {duplicate.Key} appears more than once.", "VALIDATION");
        }

        int savedId;
        try
        {
            savedId = await _adjustments.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<LandedCostAdjustmentDto>(ex);
        }

        _logger.LogInformation("Landed cost adjustment {AdjustmentId} saved by user {UserId}", savedId, userId);
        return await ReadAsync(savedId, cancellationToken);
    }

    public Task<Result<LandedCostAdjustmentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Purchase.LandedCostsPost, permissions, userId, "posted", cancellationToken,
            () => _adjustments.PostAsync(id, ToRowVersion(rowVersion), userId, cancellationToken));

    public Task<Result<LandedCostAdjustmentDto>> CancelAsync(
        int id, CancelLandedCostAdjustmentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Purchase.LandedCostsCancel, permissions, userId, "cancelled", cancellationToken,
            () => _adjustments.CancelAsync(id, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken));

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsDelete))
        {
            return Result.Failure(
                ErrorType.Forbidden, $"This action needs the {Permissions.Purchase.LandedCostsDelete} permission.", ForbiddenCode);
        }

        try
        {
            await _adjustments.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Landed cost adjustment {AdjustmentId} deleted by user {UserId}", id, userId);
        return Result.Success();
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

        return Result<(byte[], string)>.Success((BuildWorkbook(read.Value), $"LandedCost_{read.Value.DocumentNumber}.xlsx"));
    }

    /// <summary>
    /// The adjustment as somebody would file it: which invoice it belongs to, what was charged, and
    /// — the part an accountant is actually after — how each line's charge split between the stock
    /// that is still there and the goods that had already gone.
    /// </summary>
    private static byte[] BuildWorkbook(LandedCostAdjustmentDto adjustment)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Landed Cost Adjustment");

        sheet.Cell(1, 1).Value = $"Landed Cost Adjustment {adjustment.DocumentNumber}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var header = new List<(string Label, string Value)>
        {
            ("Adjustment No.", adjustment.DocumentNumber),
            ("Status", adjustment.Status),
            ("Date", adjustment.DocumentDate.ToString("dd/MM/yyyy")),
            ("Purchase Invoice", adjustment.SourceInvoiceNumber ?? string.Empty),
            ("Supplier", $"{adjustment.SupplierCode} - {adjustment.SupplierName}"),
            ("Branch", adjustment.BranchName),
            ("Warehouse", adjustment.WarehouseName),
            ("Notes", adjustment.Notes ?? string.Empty),
        };

        if (adjustment.Status == LandedCostAdjustmentStatus.Posted)
        {
            header.Add(("Posted", $"{adjustment.PostedByName} {adjustment.PostedAtUtc:dd/MM/yyyy HH:mm} UTC".Trim()));
        }

        if (adjustment.Status == LandedCostAdjustmentStatus.Cancelled)
        {
            header.Add(("Cancelled", $"{adjustment.CancelledAtUtc:dd/MM/yyyy HH:mm} {adjustment.CancelReason}".Trim()));
        }

        var row = 3;
        foreach (var (label, value) in header)
        {
            sheet.Cell(row, 1).Value = label;
            sheet.Cell(row, 1).Style.Font.Bold = true;
            sheet.Cell(row, 2).Value = value;
            row++;
        }

        row += 1;
        sheet.Cell(row, 1).Value = "Charges";
        sheet.Cell(row, 1).Style.Font.Bold = true;
        row++;

        string[] chargeColumns =
            ["#", "Code", "Charge", "Description", "Provider", "Reference", "Currency", "Rate", "Amount", "Amount (base)", "Allocation", "In landed cost", "Allocated (base)"];
        WriteHeader(sheet, row, chargeColumns);

        var firstChargeRow = row + 1;
        foreach (var charge in adjustment.Charges)
        {
            row++;
            sheet.Cell(row, 1).Value = charge.LineNumber;
            sheet.Cell(row, 2).Value = charge.ChargeCode;
            sheet.Cell(row, 3).Value = charge.ChargeName;
            sheet.Cell(row, 4).Value = charge.Description ?? string.Empty;
            sheet.Cell(row, 5).Value = charge.ProviderName ?? string.Empty;
            sheet.Cell(row, 6).Value = charge.Reference ?? string.Empty;
            sheet.Cell(row, 7).Value = charge.CurrencyCode;
            sheet.Cell(row, 8).Value = charge.ExchangeRate;
            sheet.Cell(row, 9).Value = charge.Amount;
            sheet.Cell(row, 10).Value = charge.AmountBase;
            sheet.Cell(row, 11).Value = charge.AllocationMethod;
            sheet.Cell(row, 12).Value = charge.IncludeInLandedCost ? "Yes" : "No";
            sheet.Cell(row, 13).Value = charge.AllocatedBase is { } allocated ? allocated : Blank.Value;
        }

        if (adjustment.Charges.Count > 0)
        {
            sheet.Range(firstChargeRow, 8, row, 8).Style.NumberFormat.Format = "#,##0.######";
            sheet.Range(firstChargeRow, 9, row, 10).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(firstChargeRow, 13, row, 13).Style.NumberFormat.Format = "#,##0.00";
        }

        row += 2;
        sheet.Cell(row, 1).Value = "Split over the invoice lines";
        sheet.Cell(row, 1).Style.Font.Bold = true;
        row++;

        string[] lineColumns =
        [
            "#", "Item Code", "Item Name", "Warehouse", "Received", "Net received", "Still in stock",
            "Allocated", "Extra per unit", "Inventory portion", "COGS portion", "Landed before", "Landed after",
        ];
        WriteHeader(sheet, row, lineColumns);

        var firstLineRow = row + 1;
        foreach (var line in adjustment.Lines)
        {
            row++;
            sheet.Cell(row, 1).Value = line.LineNo;
            sheet.Cell(row, 2).Value = line.ItemCode;
            sheet.Cell(row, 3).Value = line.ItemName;
            sheet.Cell(row, 4).Value = line.WarehouseCode;
            sheet.Cell(row, 5).Value = line.ReceivedBase;
            sheet.Cell(row, 6).Value = line.NetReceivedBase;
            sheet.Cell(row, 7).Value = line.RemainingBase;
            sheet.Cell(row, 8).Value = line.AllocatedBase;
            sheet.Cell(row, 9).Value = line.ExtraPerBaseUnit;
            sheet.Cell(row, 10).Value = line.InventoryPortionBase;
            sheet.Cell(row, 11).Value = line.CogsPortionBase;
            sheet.Cell(row, 12).Value = line.LandedCostBefore;
            sheet.Cell(row, 13).Value = line.LandedCostAfter;
        }

        if (adjustment.Lines.Count > 0)
        {
            sheet.Range(firstLineRow, 5, row, 7).Style.NumberFormat.Format = "#,##0";
            sheet.Range(firstLineRow, 8, row, 8).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(firstLineRow, 9, row, 9).Style.NumberFormat.Format = "#,##0.000000";
            sheet.Range(firstLineRow, 10, row, 13).Style.NumberFormat.Format = "#,##0.00";
        }

        row += 2;
        var totals = new (string Label, decimal Value)[]
        {
            ("Total charges (base)", adjustment.TotalChargesBase),
            ("Inventory portion (base)", adjustment.InventoryPortionBase),
            ("COGS portion (base)", adjustment.CogsPortionBase),
        };

        foreach (var (label, value) in totals)
        {
            sheet.Cell(row, 9).Value = label;
            sheet.Cell(row, 9).Style.Font.Bold = true;
            sheet.Cell(row, 10).Value = value;
            sheet.Cell(row, 10).Style.NumberFormat.Format = "#,##0.00";
            row++;
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(3).Width = 34;
        sheet.Column(4).Width = 26;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static void WriteHeader(IXLWorksheet sheet, int row, string[] columns)
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

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private async Task<Result<LandedCostAdjustmentDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var adjustment = await _adjustments.GetAsync(id, cancellationToken);
        return adjustment is null
            ? Result<LandedCostAdjustmentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<LandedCostAdjustmentDto>.Success(adjustment);
    }

    private async Task<Result<LandedCostAdjustmentDto>> ChangeAsync(
        int id, string permission, IReadOnlySet<string> permissions, int userId, string verb,
        CancellationToken cancellationToken, Func<Task> change)
    {
        if (!permissions.Contains(permission))
        {
            return Forbidden<LandedCostAdjustmentDto>(permission);
        }

        try
        {
            await change();
        }
        catch (BusinessRuleException ex)
        {
            return Failure<LandedCostAdjustmentDto>(ex);
        }

        _logger.LogInformation("Landed cost adjustment {AdjustmentId} {Verb} by user {UserId}", id, verb, userId);

        // Re-read: posting fills the split, moves item costs and stamps who and when.
        return await ReadAsync(id, cancellationToken);
    }

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified. THE MESSAGE IS ALWAYS THE PROCEDURE'S — "Charge 1: item
    /// X has no weight (kg)..." names the charge and the item, and only the code is added. The
    /// charges are written by the purchase engine, so its 65xxx refusals are classified here too.
    /// </summary>
    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.LandedCostValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.LandedCostConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.LandedCostNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.LandedCostNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.LandedCostInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.LandedCostSourceInvalid => new RuleFailure(ErrorType.Conflict, exception.Message, "SOURCE_INVALID"),
        SqlErrors.LandedCostImportedInvoice => new RuleFailure(ErrorType.Conflict, exception.Message, "IMPORTED_INVOICE"),
        SqlErrors.PurchaseChargesOnContainer => new RuleFailure(ErrorType.Conflict, exception.Message, "CHARGES_ON_CONTAINER"),
        SqlErrors.PurchaseChargeAllocation => new RuleFailure(ErrorType.Validation, exception.Message, "CHARGE_ALLOCATION"),
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
