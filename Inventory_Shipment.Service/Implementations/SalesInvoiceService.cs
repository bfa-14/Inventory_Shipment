using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Implementations;

public sealed class SalesInvoiceService : ISalesInvoiceService
{
    private const string NotFoundMessage = "Invoice not found.";

    private readonly ISalesDocumentRepository _invoices;
    private readonly SalesOptions _options;
    private readonly ILogger<SalesInvoiceService> _logger;

    public SalesInvoiceService(
        ISalesDocumentRepository invoices, IOptions<SalesOptions> options, ILogger<SalesInvoiceService> logger)
    {
        _invoices = invoices;
        _options = options.Value;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<SalesInvoiceListDto>>> SearchAsync(
        SalesInvoiceQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _invoices.SearchAsync(query, cancellationToken);

        return Result<PagedResult<SalesInvoiceListDto>>.Success(new PagedResult<SalesInvoiceListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<SalesInvoiceDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var invoice = await _invoices.GetAsync(id, cancellationToken);

        return invoice is null
            ? Result<SalesInvoiceDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<SalesInvoiceDto>.Success(invoice);
    }

    public async Task<Result<RateResolutionDto>> ResolveRateAsync(
        int priceListId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        if (!RateTypes.IsKnown(rateType))
        {
            return Result<RateResolutionDto>.Failure(
                ErrorType.Validation, "rateType must be 1 (Official), 2 (Non-official) or 3 (Market).", "VALIDATION");
        }

        var rate = await _invoices.ResolveRateAsync(priceListId, rateType, asOfDate, cancellationToken);

        // No row means no such price list — that IS an error. A row with a null Rate is not: it is the
        // answer "nothing is defined for that day", which the page turns into a warning and a box.
        return rate is null
            ? Result<RateResolutionDto>.Failure(ErrorType.NotFound, "Price list not found.", "NOT_FOUND")
            : Result<RateResolutionDto>.Success(rate);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<SalesInvoiceDto>> SaveDraftAsync(
        int? id, SaveSalesInvoiceRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        /* THE OVERRIDE IS A PERMISSION, READ FROM THE TOKEN. A manual price on a line changes what the
           customer is charged, and a request that could ask for the override would not need to hold
           it. The procedure receives the flag and re-prices every line accordingly. */
        var allowPriceOverride = permissions.Contains(Permissions.Sales.InvoicesPriceOverride);

        int savedId;
        try
        {
            savedId = await _invoices.SaveAsync(
                request, id, allowPriceOverride, _options.MaxDiscountPercent, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Sales invoice {InvoiceId} saved by user {UserId} (price override {Override})",
            savedId, userId, allowPriceOverride);

        return await GetAsync(savedId, cancellationToken);
    }

    public Task<Result<SalesInvoiceDto>> PostAsync(int id, string? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ChangeAsync(id, cancellationToken,
            version => _invoices.PostAsync(id, version, userId, cancellationToken), rowVersion, userId, "posted");

    public Task<Result<SalesInvoiceDto>> CancelAsync(
        int id, CancelSalesInvoiceRequest request, int userId, CancellationToken cancellationToken = default)
        => ChangeAsync(id, cancellationToken,
            version => _invoices.CancelAsync(id, request.Reason, version, userId, cancellationToken),
            request.RowVersion, userId, "cancelled");

    public async Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _invoices.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Sales invoice {InvoiceId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var fileId = await _invoices.AddFileAsync(id, fileName, contentType, content, userId, cancellationToken);
            return Result<int>.Success(fileId);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result<int>.Failure(failure.Type, failure.Message, failure.Code);
        }
    }

    public async Task<Result<SalesDocumentFileContent>> GetFileAsync(
        int id, int fileId, CancellationToken cancellationToken = default)
    {
        var file = await _invoices.GetFileAsync(fileId, cancellationToken);

        // Checked against the document in the route: file ids are sequential across every invoice.
        return file is null || file.DocumentId != id
            ? Result<SalesDocumentFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<SalesDocumentFileContent>.Success(file);
    }

    public async Task<Result> DeleteFileAsync(int id, int fileId, int userId, CancellationToken cancellationToken = default)
    {
        var file = await _invoices.GetFileAsync(fileId, cancellationToken);
        if (file is null || file.DocumentId != id)
        {
            return Result.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            await _invoices.DeleteFileAsync(fileId, userId, cancellationToken);
            return Result.Success();
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }
    }

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(int id, CancellationToken cancellationToken = default)
    {
        var invoice = await _invoices.GetAsync(id, cancellationToken);
        if (invoice is null)
        {
            return Result<(byte[], string)>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var name = string.IsNullOrWhiteSpace(invoice.DocumentNumber) ? $"DRAFT-{invoice.Id}" : invoice.DocumentNumber;
        return Result<(byte[], string)>.Success((BuildWorkbook(invoice), $"Invoice_{name}.xlsx"));
    }

    /// <summary>
    /// The invoice as somebody would file it.
    ///
    /// THE CLIENT, THE CURRENCY AND THE RATE ARE IN THE HEADER BLOCK because they are what make the
    /// numbers below mean anything: "12,125.00" is a fact only next to "USD" and "Walk-in Customer".
    /// When the invoice is not in the base currency the base equivalent is printed too, at the rate
    /// the invoice was issued at — the number the accounts will book, and the one that would
    /// otherwise have to be recomputed later with a rate that has moved.
    /// </summary>
    private static byte[] BuildWorkbook(SalesInvoiceDto invoice)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Sales Invoice");
        var money = invoice.DecimalPlaces > 0 ? "#,##0." + new string('0', invoice.DecimalPlaces) : "#,##0";

        sheet.Cell(1, 1).Value = $"Sales Invoice {invoice.DocumentNumber ?? "(draft)"}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var rateLine = invoice.IsBaseCurrency
            ? $"1 (base currency)"
            : $"1 {invoice.BaseCurrencyCode} = {invoice.ExchangeRate:0.######} {invoice.CurrencyCode} ({RateTypeName(invoice.RateType)})";

        var header = new (string Label, string Value)[]
        {
            ("Invoice No.", invoice.DocumentNumber ?? "DRAFT"),
            ("Status", invoice.Status),
            ("Invoice Date", invoice.DocumentDate.ToString("dd/MM/yyyy")),
            ("Due Date", invoice.DueDate?.ToString("dd/MM/yyyy") ?? string.Empty),
            ("Client", $"{invoice.ClientCode} - {invoice.ClientName}"),
            ("Client Phone", invoice.ClientPhone ?? string.Empty),
            ("Client Address", invoice.ClientAddress ?? string.Empty),
            ("Salesman", invoice.SalesmanName ?? string.Empty),
            ("Branch", $"{invoice.BranchCode} - {invoice.BranchName}"),
            ("Warehouse", $"{invoice.WarehouseCode} - {invoice.WarehouseName}"),
            ("Price List", invoice.PriceListName),
            ("Currency", $"{invoice.CurrencyCode} - {invoice.CurrencyName}"),
            ("Exchange Rate", rateLine),
            ("Reference", invoice.ReferenceNo ?? string.Empty),
            ("Notes", invoice.Notes ?? string.Empty),
        };

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
            ["#", "Item Code", "Item Name", "Unit", "Warehouse", "Qty", "Unit Price", "Disc %", "Discount", "Line Total", "Source", "Notes"];
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(row, i + 1).Value = columns[i];
        }

        var headerRange = sheet.Range(row, 1, row, columns.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        headerRange.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var firstLineRow = row + 1;
        foreach (var line in invoice.Lines)
        {
            row++;
            sheet.Cell(row, 1).Value = line.LineNo;
            sheet.Cell(row, 2).Value = line.ItemCode;
            sheet.Cell(row, 3).Value = line.ItemName;
            sheet.Cell(row, 4).Value = line.PackingFormula > 1 ? $"{line.UnitTypeName} (x{line.PackingFormula})" : line.UnitTypeName;
            sheet.Cell(row, 5).Value = line.WarehouseCode;
            sheet.Cell(row, 6).Value = line.Quantity;
            sheet.Cell(row, 7).Value = line.UnitPrice;
            sheet.Cell(row, 8).Value = line.DiscountPercent;
            sheet.Cell(row, 9).Value = line.LineDiscount;
            sheet.Cell(row, 10).Value = line.LineTotal;
            sheet.Cell(row, 11).Value = line.PriceSource;
            sheet.Cell(row, 12).Value = line.Notes ?? string.Empty;
        }

        if (invoice.Lines.Count > 0)
        {
            sheet.Range(firstLineRow, 7, row, 7).Style.NumberFormat.Format = money;
            sheet.Range(firstLineRow, 9, row, 10).Style.NumberFormat.Format = money;
        }

        row += 2;
        // Counts are counts and money is money: "Total Items 2.00" reads as a mistake.
        var totals = new (string Label, decimal Value, bool IsMoney)[]
        {
            ("Total Items", invoice.TotalItems, false),
            ("Total Quantity (base units)", invoice.TotalQuantity, false),
            ($"Subtotal ({invoice.CurrencyCode})", invoice.Subtotal, true),
            ($"Discount ({invoice.CurrencyCode})", invoice.TotalDiscount, true),
            ($"Total ({invoice.CurrencyCode})", invoice.TotalAmount, true),
        };

        foreach (var (label, value, isMoney) in totals)
        {
            sheet.Cell(row, 9).Value = label;
            sheet.Cell(row, 9).Style.Font.Bold = true;
            sheet.Cell(row, 10).Value = value;
            sheet.Cell(row, 10).Style.NumberFormat.Format = isMoney ? money : "0";
            row++;
        }

        if (!invoice.IsBaseCurrency)
        {
            sheet.Cell(row, 9).Value = $"Total ({invoice.BaseCurrencyCode} equivalent)";
            sheet.Cell(row, 9).Style.Font.Italic = true;
            sheet.Cell(row, 10).Value = invoice.TotalAmountBase;
            sheet.Cell(row, 10).Style.NumberFormat.Format = "#,##0.00";
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(3).Width = 40;
        sheet.Column(12).Width = 30;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string RateTypeName(byte rateType) => rateType switch
    {
        RateTypes.NonOfficial => "Non-official",
        RateTypes.Market => "Market",
        _ => "Official",
    };

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private async Task<Result<SalesInvoiceDto>> ChangeAsync(
        int id, CancellationToken cancellationToken, Func<byte[]?, Task> change,
        string? rowVersion, int userId, string verb)
    {
        try
        {
            await change(ToRowVersion(rowVersion));
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Sales invoice {InvoiceId} {Verb} by user {UserId}", id, verb, userId);

        // Re-read: posting assigns the number, writes the ledger and the cost snapshot, and moves the
        // status. The document is the server's answer, not a patch of what was sent.
        return await GetAsync(id, cancellationToken);
    }

    private static Result<SalesInvoiceDto> Failure(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<SalesInvoiceDto>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified. THE MESSAGE IS ALWAYS THE PROCEDURE'S — "Line 2: no selling
    /// price for TVS-AP160 / PC in Retail USD" names the row and the list, and only the code is added.
    /// </summary>
    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.SalesDocumentValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.SalesDocumentConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.SalesDocumentNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.SalesDocumentNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.SalesDocumentInsufficientStock => new RuleFailure(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
        SqlErrors.SalesDocumentMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),
        SqlErrors.SalesDocumentNoLines => new RuleFailure(ErrorType.Validation, exception.Message, "NO_LINES"),
        SqlErrors.SalesDocumentInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.SalesDocumentNoPrice => new RuleFailure(ErrorType.Validation, exception.Message, "NO_PRICE"),
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
