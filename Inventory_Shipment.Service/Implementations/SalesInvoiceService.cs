using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Documents;
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

    public async Task<Result<SalesInvoiceDto>> GetAsync(
        int id, IReadOnlySet<string>? permissions = null, CancellationToken cancellationToken = default)
    {
        var invoice = await _invoices.GetAsync(id, cancellationToken);

        return invoice is null
            ? Result<SalesInvoiceDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<SalesInvoiceDto>.Success(WithCostsFor(invoice, permissions));
    }

    /// <summary>
    /// The invoice as this caller may see it: without sales.profit.view, every cost and margin comes
    /// back NULL rather than absent.
    ///
    /// STRIPPED HERE, ONCE, ON THE WAY OUT. A price is everybody's business and a margin is not, and
    /// the difference is a permission rather than a screen — so it is enforced where the document
    /// leaves the service, not in the pages that draw it. Null rather than a missing field because
    /// a client that asks for a number and receives nothing has an answer either way; one that
    /// receives 0 would print a margin of zero and be believed.
    /// </summary>
    private static SalesInvoiceDto WithCostsFor(SalesInvoiceDto invoice, IReadOnlySet<string>? permissions)
    {
        // Null permissions = an internal caller that is not answering a request (the import posting).
        if (permissions is null || permissions.Contains(Permissions.Sales.ProfitView))
        {
            return invoice;
        }

        return new SalesInvoiceDto
        {
            Id = invoice.Id,
            DocumentTypeId = invoice.DocumentTypeId,
            DocumentTypeCode = invoice.DocumentTypeCode,
            DocumentTypeName = invoice.DocumentTypeName,
            NumberOnPost = invoice.NumberOnPost,
            DocumentNumber = invoice.DocumentNumber,
            DocumentDate = invoice.DocumentDate,
            DueDate = invoice.DueDate,
            BranchId = invoice.BranchId,
            BranchCode = invoice.BranchCode,
            BranchName = invoice.BranchName,
            WarehouseId = invoice.WarehouseId,
            WarehouseCode = invoice.WarehouseCode,
            WarehouseName = invoice.WarehouseName,
            ClientId = invoice.ClientId,
            ClientCode = invoice.ClientCode,
            ClientName = invoice.ClientName,
            ClientPhone = invoice.ClientPhone,
            ClientEmail = invoice.ClientEmail,
            ClientAddress = invoice.ClientAddress,
            SalesmanId = invoice.SalesmanId,
            SalesmanCode = invoice.SalesmanCode,
            SalesmanName = invoice.SalesmanName,
            PriceListId = invoice.PriceListId,
            PriceListCode = invoice.PriceListCode,
            PriceListName = invoice.PriceListName,
            CurrencyId = invoice.CurrencyId,
            CurrencyCode = invoice.CurrencyCode,
            CurrencyName = invoice.CurrencyName,
            CurrencySymbol = invoice.CurrencySymbol,
            DecimalPlaces = invoice.DecimalPlaces,
            IsBaseCurrency = invoice.IsBaseCurrency,
            RateType = invoice.RateType,
            ExchangeRate = invoice.ExchangeRate,
            BaseCurrencyCode = invoice.BaseCurrencyCode,
            ReferenceNo = invoice.ReferenceNo,
            Notes = invoice.Notes,
            Status = invoice.Status,
            TotalItems = invoice.TotalItems,
            TotalQuantity = invoice.TotalQuantity,
            Subtotal = invoice.Subtotal,
            TotalDiscount = invoice.TotalDiscount,
            TotalAmount = invoice.TotalAmount,
            TotalAmountBase = invoice.TotalAmountBase,
            TotalCostBase = null,
            TotalGrossProfitBase = null,
            TotalGrossProfitPct = null,
            SourceDocumentId = invoice.SourceDocumentId,
            SourceDocumentNumber = invoice.SourceDocumentNumber,
            PostedAtUtc = invoice.PostedAtUtc,
            PostedByName = invoice.PostedByName,
            CancelledAtUtc = invoice.CancelledAtUtc,
            CancelledByName = invoice.CancelledByName,
            CancelReason = invoice.CancelReason,
            CreatedAtUtc = invoice.CreatedAtUtc,
            CreatedByName = invoice.CreatedByName,
            UpdatedAtUtc = invoice.UpdatedAtUtc,
            UpdatedByName = invoice.UpdatedByName,
            RowVersion = invoice.RowVersion,
            Files = invoice.Files,
            Audit = invoice.Audit,
            Lines = invoice.Lines.Select(WithoutCosts).ToList(),
        };
    }

    private static SalesInvoiceLineDto WithoutCosts(SalesInvoiceLineDto line) => new()
    {
        Id = line.Id,
        LineNo = line.LineNo,
        ItemId = line.ItemId,
        ItemCode = line.ItemCode,
        ItemName = line.ItemName,
        ItemUnitId = line.ItemUnitId,
        UnitTypeName = line.UnitTypeName,
        SkuCode = line.SkuCode,
        Barcode = line.Barcode,
        PackingFormula = line.PackingFormula,
        WarehouseId = line.WarehouseId,
        WarehouseCode = line.WarehouseCode,
        WarehouseName = line.WarehouseName,
        ExpiryDate = line.ExpiryDate,
        Quantity = line.Quantity,
        QuantityBase = line.QuantityBase,
        UnitPrice = line.UnitPrice,
        DiscountPercent = line.DiscountPercent,
        LineDiscount = line.LineDiscount,
        LineTotal = line.LineTotal,
        PriceSource = line.PriceSource,
        UnitCostBase = null,
        FobCostAtSale = null,
        LastCostAtSale = null,
        NetSalesBase = null,
        CogsBase = null,
        GrossProfitBase = null,
        GrossProfitPct = null,
        ReturnedQuantityBase = line.ReturnedQuantityBase,
        RemainingBase = line.RemainingBase,
        ImportRowNumber = line.ImportRowNumber,
        Notes = line.Notes,
        OnHandBase = line.OnHandBase,
        SystemPrice = line.SystemPrice,
        ItemAverageCost = null,
    };

    public async Task<Result<IReadOnlyList<string>>> ItemSpecificationsAsync(
        int itemId, CancellationToken cancellationToken = default)
    {
        var rows = await _invoices.ItemSpecificationsAsync(itemId, cancellationToken);
        return Result<IReadOnlyList<string>>.Success(rows);
    }

    public async Task<Result<RateResolutionDto>> ResolveRateAsync(
        int priceListId, byte rateType, DateOnly? asOfDate, int? currencyId = null, CancellationToken cancellationToken = default)
    {
        if (!RateTypes.IsKnown(rateType))
        {
            return Result<RateResolutionDto>.Failure(
                ErrorType.Validation, "rateType must be 1 (Official), 2 (Non-official) or 3 (Market).", "VALIDATION");
        }

        var rate = await _invoices.ResolveRateAsync(priceListId, rateType, asOfDate, currencyId, cancellationToken);

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

        return await GetAsync(savedId, permissions, cancellationToken);
    }

    public async Task<Result<SalesInvoiceDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string>? permissions = null,
        CancellationToken cancellationToken = default, bool acknowledgeOutOfStock = false)
    {
        /* A CASH INVOICE ALSO POSTS A RECEIPT, so posting it needs the receipt-posting right as well.
           Otherwise the invoice screen would be a way to take money in that the receipt screen would
           refuse the same person. Checked before anything is attempted; the procedure still decides
           the rest. A null permission set means an internal caller that has already been authorised. */
        if (permissions is not null)
        {
            var existing = await _invoices.GetAsync(id, cancellationToken);
            if (existing?.PaymentType == SalesPaymentTypes.Cash && !permissions.Contains(Permissions.Sales.ReceiptsPost))
            {
                return Result<SalesInvoiceDto>.Failure(
                    ErrorType.Forbidden,
                    $"Posting a Cash invoice also posts its receipt, which needs the {Permissions.Sales.ReceiptsPost} permission.",
                    "FORBIDDEN");
            }
        }

        return await ChangeAsync(id, cancellationToken,
            version => _invoices.PostAsync(id, version, userId, cancellationToken, acknowledgeOutOfStock), rowVersion, userId, "posted", permissions);
    }

    public async Task<Result<StockCheckDto>> StockCheckAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            var lines = await _invoices.GetOutOfStockLinesAsync(id, cancellationToken);
            return Result<StockCheckDto>.Success(new StockCheckDto { Lines = lines });
        }
        catch (BusinessRuleException ex)
        {
            return Failure<StockCheckDto>(ex);
        }
    }

    /// <summary>
    /// A sales return draft from a posted invoice: what has not already come back, at the invoice's
    /// prices and its ORIGINAL cost of sales. There is no returns page yet — the caller gets the
    /// draft and its number, and the page says so.
    /// </summary>
    public async Task<Result<SalesInvoiceDto>> CreateReturnAsync(
        int id, DateOnly? documentDate, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.InvoicesCreate))
        {
            return Result<SalesInvoiceDto>.Failure(
                ErrorType.Forbidden, $"This action needs the {Permissions.Sales.InvoicesCreate} permission.", "FORBIDDEN");
        }

        int newId;
        try
        {
            newId = await _invoices.CreateFromSourceAsync(id, documentDate, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Sales return {ReturnId} created from invoice {InvoiceId} by user {UserId}", newId, id, userId);
        return await GetAsync(newId, permissions, cancellationToken);
    }

    public async Task<Result<ImportPostResult>> ImportPostAsync(
        SaveSalesInvoiceRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        /* THE SECOND PERMISSION. [HasPermission] on the action checks sales.invoices.post; a poster
           who cannot create must not get an invoice made for them on the way through, so the create
           right is checked here, before a single row is written. */
        if (!permissions.Contains(Permissions.Sales.InvoicesCreate))
        {
            return Result<ImportPostResult>.Failure(
                ErrorType.Forbidden, "Posting an import also requires the sales.invoices.create permission.", "FORBIDDEN");
        }

        if (request.PaymentType == SalesPaymentTypes.Cash && !permissions.Contains(Permissions.Sales.ReceiptsPost))
        {
            return Result<ImportPostResult>.Failure(
                ErrorType.Forbidden,
                $"Posting a Cash invoice also posts its receipt, which needs the {Permissions.Sales.ReceiptsPost} permission.",
                "FORBIDDEN");
        }

        var allowPriceOverride = permissions.Contains(Permissions.Sales.InvoicesPriceOverride);

        int id;
        try
        {
            id = await _invoices.SaveAsync(
                request, null, allowPriceOverride, _options.MaxDiscountPercent, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ImportPostResult>(ex);
        }

        try
        {
            // No row version: the draft was created a moment ago by this very call and nobody else
            // has had the chance to touch it.
            await _invoices.PostAsync(id, null, userId, cancellationToken, request.AcknowledgeOutOfStock);
        }
        catch (BusinessRuleException ex)
        {
            /* THE DRAFT MUST NOT OUTLIVE THE FAILURE. The page shows the error and keeps its lines
               for the user to fix and re-post; an invisible draft left here would be posted twice
               over by the retry, or sit forever in a list nobody opens from this page. */
            await DeleteFailedDraftAsync(id, userId);
            return Failure<ImportPostResult>(ex);
        }

        _logger.LogInformation(
            "Sales invoice {InvoiceId} imported and posted by user {UserId} (price override {Override})",
            id, userId, allowPriceOverride);

        var invoice = await _invoices.GetAsync(id, cancellationToken);
        if (invoice is null)
        {
            return Result<ImportPostResult>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        return Result<ImportPostResult>.Success(new ImportPostResult
        {
            Id = invoice.Id,
            DocumentNumber = invoice.DocumentNumber ?? string.Empty,
            TotalItems = invoice.TotalItems,
            TotalQuantity = invoice.TotalQuantity,
            Subtotal = invoice.Subtotal,
            TotalDiscount = invoice.TotalDiscount,
            TotalAmount = invoice.TotalAmount,
            CurrencyCode = invoice.CurrencyCode,
            CurrencySymbol = invoice.CurrencySymbol,
            DecimalPlaces = invoice.DecimalPlaces,
            TotalAmountBase = invoice.TotalAmountBase,
            BaseCurrencyCode = invoice.BaseCurrencyCode,
            ExchangeRate = invoice.ExchangeRate,
            PostedAtUtc = invoice.PostedAtUtc,
            // The posting procedure writes exactly one ledger row per line.
            MovementsWritten = invoice.Lines.Count,
        });
    }

    /// <summary>
    /// Best effort, and it must not throw: the error the caller is about to receive is the posting
    /// failure, and a second failure here would replace it with one about a draft the page never
    /// knew about. CancellationToken.None because a caller that has already gone away is exactly the
    /// case in which cleaning up matters most.
    /// </summary>
    private async Task DeleteFailedDraftAsync(int id, int userId)
    {
        try
        {
            await _invoices.DeleteAsync(id, userId, CancellationToken.None);
            _logger.LogInformation("Sales invoice draft {InvoiceId} deleted after its import posting failed", id);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Sales invoice draft {InvoiceId} could not be deleted after its import posting failed", id);
        }
    }

    public async Task<Result<SalesInvoiceDto>> CancelAsync(
        int id, CancelSalesInvoiceRequest request, int userId, IReadOnlySet<string>? permissions = null,
        CancellationToken cancellationToken = default)
    {
        /* CANCELLING A PAID CASH INVOICE REVERSES ITS RECEIPT IN THE SAME STEP, so it needs the right to
           reverse a receipt too: this is "the authorised reversal process" of the requirement. */
        if (permissions is not null)
        {
            var existing = await _invoices.GetAsync(id, cancellationToken);
            if (existing is { ReceiptStatus: "Posted" } && !permissions.Contains(Permissions.Sales.ReceiptsReverse))
            {
                return Result<SalesInvoiceDto>.Failure(
                    ErrorType.Forbidden,
                    $"Cancelling this invoice also reverses its receipt {existing.ReceiptNumber}, which needs the {Permissions.Sales.ReceiptsReverse} permission.",
                    "FORBIDDEN");
            }
        }

        return await ChangeAsync(id, cancellationToken,
            version => _invoices.CancelAsync(id, request.Reason, version, userId, cancellationToken),
            request.RowVersion, userId, "cancelled", permissions);
    }

    public Task<BulkActionResult> BulkPostAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => BulkDocumentActions.RunAsync(ids, async id =>
        {
            var posted = await PostAsync(id, null, userId, permissions, cancellationToken);
            return posted.IsSuccess && posted.Value is not null
                ? Result<string?>.Success(posted.Value.DocumentNumber)
                : Result<string?>.Failure(posted.ErrorType, posted.Error ?? string.Empty, posted.Code ?? "ERROR");
        });

    public Task<BulkActionResult> BulkDeleteAsync(IReadOnlyList<int> ids, int userId, CancellationToken cancellationToken = default)
        => BulkDocumentActions.RunAsync(ids, async id =>
        {
            var deleted = await DeleteAsync(id, userId, cancellationToken);
            return deleted.IsSuccess
                ? Result<string?>.Success(null)
                : Result<string?>.Failure(deleted.ErrorType, deleted.Error ?? string.Empty, deleted.Code ?? "ERROR");
        });

    /// <summary>
    /// The imported file's lines, saved as ONE invoice whatever warehouses they name — the warehouse
    /// is a line's, so a file naming several becomes one invoice whose rows each keep their own.
    ///
    /// THE DRAFT REFERENCE GOES ON THAT INVOICE. The import logs written while no invoice existed are
    /// attached to it by the save, which gives it its "Imported" audit row. A refused posting leaves
    /// the invoice as a draft: the lines are worth more than a clean failure.
    /// </summary>
    public async Task<Result<ImportCreateResult>> ImportCreateAsync(
        ImportCreateSalesInvoicesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.InvoicesCreate)
            || (request.PostImmediately && !permissions.Contains(Permissions.Sales.InvoicesPost)))
        {
            return Result<ImportCreateResult>.Failure(
                ErrorType.Forbidden, "Creating invoices from an import needs sales.invoices.create, and sales.invoices.post to post them.", "FORBIDDEN");
        }

        if (request.Lines.Count == 0)
        {
            return Result<ImportCreateResult>.Failure(ErrorType.Validation, "The file has no lines to import.", "NO_LINES");
        }

        var documents = new List<ImportCreateDocument>();
        var failed = new List<ImportCreateFailure>();
        var posted = 0;
        var warehouseCount = request.Lines.Select(line => line.WarehouseId).Distinct().Count();

        var draft = new SaveSalesInvoiceRequest
        {
            DocumentDate = request.DocumentDate,
            DueDate = request.DueDate,
            BranchId = request.BranchId,
            // Left for the database, which takes the first line's: the header warehouse is only a label.
            WarehouseId = null,
            ClientId = request.ClientId,
            SalesmanId = request.SalesmanId,
            PriceListId = request.PriceListId,
            RateType = request.RateType,
            ExchangeRate = request.ExchangeRate,
            ReferenceNo = request.ReferenceNo,
            Notes = request.Notes,
            DraftReference = request.DraftReference,
            PaymentType = request.PaymentType,
            ReceiptMethodId = request.ReceiptMethodId,
            ReceiptAccountId = request.ReceiptAccountId,
            PaymentReference = request.PaymentReference,
            Lines = request.Lines.Select((line, index) => new SaveSalesInvoiceLineRequest
            {
                LineNo = index + 1,
                ItemId = line.ItemId,
                ItemUnitId = line.ItemUnitId,
                // THE ROW'S OWN WAREHOUSE, the one the file named on that row.
                WarehouseId = line.WarehouseId,
                ExpiryDate = line.ExpiryDate,
                Quantity = line.Quantity,
                UnitPrice = line.UnitPrice,
                DiscountPercent = line.DiscountPercent,
                ImportRowNumber = line.ImportRowNumber,
                Notes = line.Notes,
            }).ToList(),
        };

        var saved = await SaveDraftAsync(null, draft, userId, permissions, cancellationToken);
        if (saved.IsFailure || saved.Value is null)
        {
            failed.Add(new ImportCreateFailure
            {
                Code = saved.Code ?? "ERROR",
                Message = saved.Error ?? "The invoice could not be created.",
            });
        }
        else
        {
            var invoice = saved.Value;
            if (request.PostImmediately)
            {
                var result = await PostAsync(invoice.Id, null, userId, permissions, cancellationToken);
                if (result.IsSuccess && result.Value is not null)
                {
                    invoice = result.Value;
                    posted++;
                }
                else
                {
                    failed.Add(new ImportCreateFailure
                    {
                        WarehouseId = invoice.WarehouseId,
                        WarehouseName = invoice.WarehouseName,
                        Code = result.Code ?? "ERROR",
                        Message = result.Error ?? "The invoice could not be posted.",
                    });
                }
            }

            documents.Add(new ImportCreateDocument
            {
                Id = invoice.Id,
                DocumentNumber = invoice.DocumentNumber,
                WarehouseId = invoice.WarehouseId,
                WarehouseName = invoice.WarehouseName,
                WarehouseCount = warehouseCount,
                LineCount = invoice.Lines.Count,
                Status = invoice.Status,
            });
        }

        _logger.LogInformation(
            "Import created {Created} sales invoice(s) spanning {Warehouses} warehouse(s) for user {UserId}: {Posted} posted, {Failed} refused",
            documents.Count, warehouseCount, userId, posted, failed.Count);

        return Result<ImportCreateResult>.Success(new ImportCreateResult
        {
            Documents = documents,
            Created = documents.Count,
            Posted = posted,
            Failed = failed,
        });
    }

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
        string? rowVersion, int userId, string verb, IReadOnlySet<string>? permissions = null)
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
        return await GetAsync(id, permissions, cancellationToken);
    }

    private static Result<SalesInvoiceDto> Failure(BusinessRuleException exception)
        => Failure<SalesInvoiceDto>(exception);

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
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
        SqlErrors.SalesDocumentOutOfStockConfirm => new RuleFailure(ErrorType.Conflict, exception.Message, "OUT_OF_STOCK_CONFIRM"),
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
