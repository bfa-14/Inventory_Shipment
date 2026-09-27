using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
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

public sealed class PurchaseDocumentService : IPurchaseDocumentService
{
    private const string NotFoundMessage = "Document not found.";
    private const string ForbiddenCode = "FORBIDDEN";

    private readonly IPurchaseDocumentRepository _documents;
    private readonly PurchaseOptions _options;
    private readonly ILogger<PurchaseDocumentService> _logger;

    public PurchaseDocumentService(
        IPurchaseDocumentRepository documents, IOptions<PurchaseOptions> options, ILogger<PurchaseDocumentService> logger)
    {
        _documents = documents;
        _options = options.Value;
        _logger = logger;
    }

    /* ── the permission sets ──────────────────────────────────────────────────────────────────── */

    /// <summary>The five verbs of one kind of purchase document.</summary>
    private sealed record PermissionSet(string Label, string View, string Create, string Post, string Cancel, string Delete);

    private static readonly PermissionSet Orders = new("purchase order",
        Permissions.Purchase.OrdersView, Permissions.Purchase.OrdersCreate, Permissions.Purchase.OrdersPost,
        Permissions.Purchase.OrdersCancel, Permissions.Purchase.OrdersDelete);

    private static readonly PermissionSet Invoices = new("purchase invoice",
        Permissions.Purchase.InvoicesView, Permissions.Purchase.InvoicesCreate, Permissions.Purchase.InvoicesPost,
        Permissions.Purchase.InvoicesCancel, Permissions.Purchase.InvoicesDelete);

    private static readonly PermissionSet Returns = new("purchase return",
        Permissions.Purchase.ReturnsView, Permissions.Purchase.ReturnsCreate, Permissions.Purchase.ReturnsPost,
        Permissions.Purchase.ReturnsCancel, Permissions.Purchase.ReturnsDelete);

    private static PermissionSet? SetFor(string? documentTypeCode) => PurchaseDocumentTypes.Normalize(documentTypeCode) switch
    {
        PurchaseDocumentTypes.Order => Orders,
        PurchaseDocumentTypes.Invoice => Invoices,
        PurchaseDocumentTypes.Return => Returns,
        _ => null,
    };

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    private static Result<T> UnknownType<T>()
        => Result<T>.Failure(ErrorType.Validation, "documentTypeCode must be PO, PINV or PRET.", "VALIDATION");

    /// <summary>
    /// The document's kind and status, once the caller is allowed the verb on that kind.
    ///
    /// READ BEFORE ACT, EVERY TIME: the permission an action needs is the document's to tell, so the
    /// stub is read first and the procedure runs only after the check has passed. A missing document
    /// is 404 before it is 403 — there is nothing to be forbidden from.
    /// </summary>
    private async Task<Result<PurchaseDocumentStub>> AllowAsync(
        int id, Func<PermissionSet, string> verb, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var stub = await _documents.GetStubAsync(id, cancellationToken);
        if (stub is null)
        {
            return Result<PurchaseDocumentStub>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var set = SetFor(stub.DocumentTypeCode);
        if (set is null)
        {
            return Result<PurchaseDocumentStub>.Failure(ErrorType.Validation, "The document is not a purchase document.", "VALIDATION");
        }

        var required = verb(set);
        return permissions.Contains(required)
            ? Result<PurchaseDocumentStub>.Success(stub)
            : Forbidden<PurchaseDocumentStub>(required);
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<PurchaseDocumentListDto>>> SearchAsync(
        PurchaseDocumentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        /* THE LIST IS ONE KIND AT A TIME. The procedure could return the whole family, but each kind
           is its own view permission and a mixed list would have to be filtered here by rights the
           procedure never sees. One kind per request keeps the permission and the page the same shape. */
        var set = SetFor(query.DocumentTypeCode);
        if (set is null)
        {
            return UnknownType<PagedResult<PurchaseDocumentListDto>>();
        }

        if (!permissions.Contains(set.View))
        {
            return Forbidden<PagedResult<PurchaseDocumentListDto>>(set.View);
        }

        var (items, totalCount) = await _documents.SearchAsync(query, cancellationToken);

        return Result<PagedResult<PurchaseDocumentListDto>>.Success(new PagedResult<PurchaseDocumentListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<PurchaseDocumentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var document = await _documents.GetAsync(id, cancellationToken);
        if (document is null)
        {
            return Result<PurchaseDocumentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var set = SetFor(document.DocumentTypeCode);
        return set is not null && !permissions.Contains(set.View)
            ? Forbidden<PurchaseDocumentDto>(set.View)
            : Result<PurchaseDocumentDto>.Success(document);
    }

    public async Task<Result<PurchaseRateResolutionDto>> ResolveRateAsync(
        int currencyId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        if (!RateTypes.IsKnown(rateType))
        {
            return Result<PurchaseRateResolutionDto>.Failure(
                ErrorType.Validation, "rateType must be 1 (Official), 2 (Non-official) or 3 (Market).", "VALIDATION");
        }

        var rate = await _documents.ResolveRateAsync(currencyId, rateType, asOfDate, cancellationToken);

        // No row means no such currency — that IS an error. A row with a null Rate is not: it is the
        // answer "nothing is defined for that day", which the page turns into a warning and a box.
        return rate is null
            ? Result<PurchaseRateResolutionDto>.Failure(ErrorType.NotFound, "Currency not found.", "NOT_FOUND")
            : Result<PurchaseRateResolutionDto>.Success(rate);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PurchaseDocumentDto>> SaveDraftAsync(
        int? id, SavePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var set = SetFor(request.DocumentTypeCode);
        if (set is null)
        {
            return UnknownType<PurchaseDocumentDto>();
        }

        if (!permissions.Contains(set.Create))
        {
            return Forbidden<PurchaseDocumentDto>(set.Create);
        }

        if (id is { } existingId)
        {
            // The kind of an existing draft is the kind of the request, or the procedure refuses it; the
            // permission check has to be made on the stored kind too, or a caller could edit an invoice
            // by calling it an order.
            var allowed = await AllowAsync(existingId, s => s.Create, permissions, cancellationToken);
            if (allowed.IsFailure)
            {
                return Result<PurchaseDocumentDto>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
            }
        }

        int savedId;
        try
        {
            savedId = await _documents.SaveAsync(request, id, _options.MaxDiscountPercent, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PurchaseDocumentDto>(ex);
        }

        _logger.LogInformation("{Kind} {DocumentId} saved by user {UserId}", set.Label, savedId, userId);

        return await ReadAsync(savedId, cancellationToken);
    }

    public async Task<Result<PurchaseDocumentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Post, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result<PurchaseDocumentDto>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        return await ChangeAsync(id, cancellationToken,
            version => _documents.PostAsync(id, version, userId, cancellationToken), rowVersion, userId, "posted");
    }

    public async Task<Result<PurchaseDocumentDto>> CancelAsync(
        int id, CancelPurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Cancel, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result<PurchaseDocumentDto>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        return await ChangeAsync(id, cancellationToken,
            version => _documents.CancelAsync(id, request.Reason, version, userId, cancellationToken),
            request.RowVersion, userId, "cancelled");
    }

    /// <summary>
    /// CLOSING IS THE POSTER'S RIGHT. Whoever may confirm an order decides when it is done: closing
    /// reverses nothing and keeps every receipt, so it is a step of the order's life rather than the
    /// undoing that cancelling is. The procedure refuses anything that is not an open order.
    /// </summary>
    public async Task<Result<PurchaseDocumentDto>> CloseAsync(
        int id, ClosePurchaseDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Post, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result<PurchaseDocumentDto>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        return await ChangeAsync(id, cancellationToken,
            version => _documents.CloseAsync(id, request.Reason, version, userId, cancellationToken),
            request.RowVersion, userId, "closed");
    }

    /// <summary>
    /// RECORDING A SHIPMENT IS EDITING THE ORDER, so it is the order's create right — the same person
    /// who typed the quantities types what the supplier says has left. It moves no stock: the shipped
    /// quantity is only what the shortage plan reads as Transit until the invoice receives it.
    /// </summary>
    public async Task<Result<PurchaseDocumentDto>> MarkShippedAsync(
        int id, MarkShippedRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.OrdersCreate))
        {
            return Forbidden<PurchaseDocumentDto>(Permissions.Purchase.OrdersCreate);
        }

        if (request.Lines.GroupBy(l => l.LineId).Any(g => g.Count() > 1))
        {
            return Result<PurchaseDocumentDto>.Failure(ErrorType.Validation, "A line appears more than once.", "VALIDATION");
        }

        return await ChangeAsync(id, cancellationToken,
            version => _documents.MarkShippedAsync(id, request.Lines, version, userId, cancellationToken),
            request.RowVersion, userId, "marked as shipped");
    }

    /// <summary>
    /// The charges of a draft invoice — freight, customs, clearing — replacing whatever was there.
    ///
    /// EDITING CHARGES IS EDITING THE INVOICE, so it is the invoice's create right. It is refused on
    /// anything that is not a DRAFT PURCHASE INVOICE: once the goods are received the cost is
    /// already in the ledger, and a charge arriving later is a landed cost adjustment instead.
    /// </summary>
    public async Task<Result<PurchaseDocumentDto>> SetChargesAsync(
        int id, SetPurchaseChargesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Create, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result<PurchaseDocumentDto>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        if (allowed.Value!.DocumentTypeCode != PurchaseDocumentTypes.Invoice)
        {
            return Result<PurchaseDocumentDto>.Failure(
                ErrorType.Conflict,
                "Charges are entered on purchase invoices only (use a Landed Cost Adjustment after posting).", "INVALID_STATUS");
        }

        // Said here with the numbers the page shows; the table type's primary key would refuse the
        // batch too, but with a message about a constraint nobody on the page has heard of.
        var duplicate = request.Charges.GroupBy(c => c.LineNumber).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            return Result<PurchaseDocumentDto>.Failure(
                ErrorType.Validation, $"Charge {duplicate.Key} appears more than once.", "VALIDATION");
        }

        return await ChangeAsync(id, cancellationToken,
            version => _documents.SetChargesAsync(id, request, version, userId, cancellationToken),
            request.RowVersion, userId, "charges saved");
    }

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Delete, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        try
        {
            await _documents.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Purchase document {DocumentId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    public async Task<Result<PurchaseDocumentDto>> CreateFromSourceAsync(
        int sourceId, string targetTypeCode, CreateFromSourceRequest request, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var target = PurchaseDocumentTypes.Normalize(targetTypeCode);
        var set = SetFor(target);
        if (set is null || target == PurchaseDocumentTypes.Order)
        {
            return Result<PurchaseDocumentDto>.Failure(
                ErrorType.Validation, "Only purchase invoices (from orders) and purchase returns (from invoices) can be created from a source.", "VALIDATION");
        }

        /* THE PERMISSION IS THE TARGET'S. Making an invoice from an order is creating an invoice;
           seeing the order is checked too, because the new draft copies its lines. */
        if (!permissions.Contains(set.Create))
        {
            return Forbidden<PurchaseDocumentDto>(set.Create);
        }

        var source = await AllowAsync(sourceId, s => s.View, permissions, cancellationToken);
        if (source.IsFailure)
        {
            return Result<PurchaseDocumentDto>.Failure(source.ErrorType, source.Error ?? string.Empty, source.Code ?? "ERROR");
        }

        int newId;
        try
        {
            newId = await _documents.CreateFromSourceAsync(sourceId, target!, request.DocumentDate, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PurchaseDocumentDto>(ex);
        }

        _logger.LogInformation("{Kind} {DocumentId} created from {SourceNumber} by user {UserId}",
            set.Label, newId, source.Value!.DocumentNumber, userId);

        return await ReadAsync(newId, cancellationToken);
    }

    /// <summary>
    /// AN INVOICE FROM CONTAINERS IS AN INVOICE: the right is purchase.invoices.create, and seeing the
    /// order is checked too because the draft copies its prices. The answer is the new id only — the
    /// page opens the draft next.
    /// </summary>
    public async Task<Result<int>> CreateFromContainersAsync(
        int purchaseOrderId, InvoiceFromContainersRequest request, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Invoices.Create))
        {
            return Forbidden<int>(Invoices.Create);
        }

        var duplicate = request.Lines.GroupBy(l => l.ContainerLineId).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            return Result<int>.Failure(
                ErrorType.Validation, $"Container line {duplicate.Key} appears more than once.", "VALIDATION");
        }

        var order = await AllowAsync(purchaseOrderId, s => s.View, permissions, cancellationToken);
        if (order.IsFailure)
        {
            return Result<int>.Failure(order.ErrorType, order.Error ?? string.Empty, order.Code ?? "ERROR");
        }

        int newId;
        try
        {
            newId = await _documents.CreateFromContainersAsync(
                purchaseOrderId, request.Lines, request.DocumentDate, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }

        _logger.LogInformation("Purchase invoice {DocumentId} created from the containers of {OrderNumber} by user {UserId}",
            newId, order.Value!.DocumentNumber, userId);

        return Result<int>.Success(newId);
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

    public Task<BulkActionResult> BulkDeleteAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => BulkDocumentActions.RunAsync(ids, async id =>
        {
            var deleted = await DeleteAsync(id, userId, permissions, cancellationToken);
            return deleted.IsSuccess
                ? Result<string?>.Success(null)
                : Result<string?>.Failure(deleted.ErrorType, deleted.Error ?? string.Empty, deleted.Code ?? "ERROR");
        });

    /// <summary>
    /// The imported file's lines, sorted into one document per warehouse and saved one by one. A
    /// refused posting leaves its document as a draft: the lines are worth more than a clean failure.
    /// </summary>
    public async Task<Result<ImportCreateResult>> ImportCreateAsync(
        ImportCreatePurchaseDocumentsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var set = SetFor(request.DocumentTypeCode);
        if (set is null)
        {
            return UnknownType<ImportCreateResult>();
        }

        if (!permissions.Contains(set.Create) || (request.PostImmediately && !permissions.Contains(set.Post)))
        {
            return Result<ImportCreateResult>.Failure(
                ErrorType.Forbidden, $"Creating {set.Label}s from an import needs {set.Create}, and {set.Post} to post them.", ForbiddenCode);
        }

        if (request.Lines.Count == 0)
        {
            return Result<ImportCreateResult>.Failure(ErrorType.Validation, "The file has no lines to import.", "NO_LINES");
        }

        var documents = new List<ImportCreateDocument>();
        var failed = new List<ImportCreateFailure>();
        var posted = 0;

        foreach (var (warehouseId, lines) in WarehouseGrouping.GroupLinesByWarehouse(request.Lines, line => line.WarehouseId))
        {
            var draft = new SavePurchaseDocumentRequest
            {
                DocumentTypeCode = request.DocumentTypeCode,
                DocumentDate = request.DocumentDate,
                ExpectedDate = request.ExpectedDate,
                BranchId = request.BranchId,
                WarehouseId = warehouseId,
                SupplierId = request.SupplierId,
                CurrencyId = request.CurrencyId,
                RateType = request.RateType,
                ExchangeRate = request.ExchangeRate,
                SupplierReference = request.SupplierReference,
                Notes = request.Notes,
                Lines = lines.Select((line, index) => new SavePurchaseDocumentLineRequest
                {
                    LineNo = index + 1,
                    ItemId = line.ItemId,
                    ItemUnitId = line.ItemUnitId,
                    WarehouseId = warehouseId,
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
                    WarehouseId = warehouseId,
                    Code = saved.Code ?? "ERROR",
                    Message = saved.Error ?? "The document could not be created.",
                });
                continue;
            }

            var document = saved.Value;
            if (request.PostImmediately)
            {
                var result = await PostAsync(document.Id, null, userId, permissions, cancellationToken);
                if (result.IsSuccess && result.Value is not null)
                {
                    document = result.Value;
                    posted++;
                }
                else
                {
                    failed.Add(new ImportCreateFailure
                    {
                        WarehouseId = warehouseId,
                        WarehouseName = document.WarehouseName,
                        Code = result.Code ?? "ERROR",
                        Message = result.Error ?? "The document could not be posted.",
                    });
                }
            }

            documents.Add(new ImportCreateDocument
            {
                Id = document.Id,
                DocumentNumber = document.DocumentNumber,
                WarehouseId = warehouseId,
                WarehouseName = document.WarehouseName,
                LineCount = document.Lines.Count,
                Status = document.Status,
            });
        }

        _logger.LogInformation(
            "Import created {Created} {Kind}(s) for user {UserId}: {Posted} posted, {Failed} refused",
            documents.Count, set.Label, userId, posted, failed.Count);

        return Result<ImportCreateResult>.Success(new ImportCreateResult
        {
            Documents = documents,
            Created = documents.Count,
            Posted = posted,
            Failed = failed,
        });
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Create, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result<int>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        try
        {
            var fileId = await _documents.AddFileAsync(id, fileName, contentType, content, userId, cancellationToken);
            return Result<int>.Success(fileId);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }
    }

    public async Task<Result<PurchaseDocumentFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.View, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result<PurchaseDocumentFileContent>.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        var file = await _documents.GetFileAsync(fileId, cancellationToken);

        // Checked against the document in the route: file ids are sequential across every document.
        return file is null || file.DocumentId != id
            ? Result<PurchaseDocumentFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<PurchaseDocumentFileContent>.Success(file);
    }

    public async Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var allowed = await AllowAsync(id, s => s.Create, permissions, cancellationToken);
        if (allowed.IsFailure)
        {
            return Result.Failure(allowed.ErrorType, allowed.Error ?? string.Empty, allowed.Code ?? "ERROR");
        }

        var file = await _documents.GetFileAsync(fileId, cancellationToken);
        if (file is null || file.DocumentId != id)
        {
            return Result.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            await _documents.DeleteFileAsync(fileId, userId, cancellationToken);
            return Result.Success();
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }
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

        var document = read.Value;
        var name = string.IsNullOrWhiteSpace(document.DocumentNumber) ? $"DRAFT-{document.Id}" : document.DocumentNumber;
        var prefix = document.DocumentTypeCode switch
        {
            PurchaseDocumentTypes.Order => "PurchaseOrder",
            PurchaseDocumentTypes.Return => "PurchaseReturn",
            _ => "PurchaseInvoice",
        };

        return Result<(byte[], string)>.Success((BuildWorkbook(document), $"{prefix}_{name}.xlsx"));
    }

    /// <summary>
    /// The document as somebody would file it: the supplier, the currency and the rate in the header
    /// block because they are what make the numbers below mean anything, the base equivalent printed
    /// when the currency is not the base one, and — for an order — what has been received so far.
    /// </summary>
    private static byte[] BuildWorkbook(PurchaseDocumentDto document)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(document.DocumentTypeName.Length <= 31 ? document.DocumentTypeName : "Purchase Document");
        var money = document.DecimalPlaces > 0 ? "#,##0." + new string('0', document.DecimalPlaces) : "#,##0";

        sheet.Cell(1, 1).Value = $"{document.DocumentTypeName} {document.DocumentNumber ?? "(draft)"}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var rateLine = document.IsBaseCurrency
            ? "1 (base currency)"
            : $"1 {document.BaseCurrencyCode} = {document.ExchangeRate:0.######} {document.CurrencyCode} ({RateTypeName(document.RateType)})";

        var header = new List<(string Label, string Value)>
        {
            ("Document No.", document.DocumentNumber ?? "DRAFT"),
            ("Status", document.Status),
            ("Document Date", document.DocumentDate.ToString("dd/MM/yyyy")),
            (document.DocumentTypeCode == PurchaseDocumentTypes.Order ? "Expected Date" : "Due Date",
                document.ExpectedDate?.ToString("dd/MM/yyyy") ?? string.Empty),
            ("Supplier", $"{document.SupplierCode} - {document.SupplierName}"),
            ("Supplier Phone", document.SupplierPhone ?? string.Empty),
            ("Supplier Address", document.SupplierAddress ?? string.Empty),
            ("Supplier Reference", document.SupplierReference ?? string.Empty),
            ("Branch", $"{document.BranchCode} - {document.BranchName}"),
            ("Warehouse", $"{document.WarehouseCode} - {document.WarehouseName}"),
            ("Currency", $"{document.CurrencyCode} - {document.CurrencyName}"),
            ("Exchange Rate", rateLine),
            ("Source Document", document.SourceDocumentNumber ?? string.Empty),
            ("Notes", document.Notes ?? string.Empty),
        };

        if (document.DocumentTypeCode == PurchaseDocumentTypes.Invoice)
        {
            // Inserted after the supplier's own reference: the three numbers the supplier's paperwork quotes.
            var at = header.FindIndex(h => h.Label == "Supplier Reference") + 1;
            header.InsertRange(at,
            [
                ("Exporter Ref.", document.ExporterReference ?? string.Empty),
                ("Commercial Invoice No.", document.CommercialInvoiceNo ?? string.Empty),
                ("Receipt Mode", document.ReceiptMode == PurchaseReceiptModes.OnContainerOffload ? "On container offload" : "On posting"),
            ]);
        }

        if (document.Status == PurchaseDocumentStatus.Closed)
        {
            header.Add(("Closed", $"{document.ClosedAtUtc:dd/MM/yyyy} {document.CloseReason}".Trim()));
        }

        if (document.Status == PurchaseDocumentStatus.Cancelled)
        {
            header.Add(("Cancelled", $"{document.CancelledAtUtc:dd/MM/yyyy} {document.CancelReason}".Trim()));
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
        var progressLabel = document.DocumentTypeCode switch
        {
            PurchaseDocumentTypes.Order => "Received (base)",
            PurchaseDocumentTypes.Invoice => "Returned (base)",
            _ => "Unit Cost (base)",
        };
        string[] columns =
            ["#", "Item Code", "Item Name", "Unit", "Qty", "Unit Price", "Disc %", "Discount", "Line Total", progressLabel, "Expiry", "Notes"];
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(row, i + 1).Value = columns[i];
        }

        var headerRange = sheet.Range(row, 1, row, columns.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        headerRange.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var firstLineRow = row + 1;
        foreach (var line in document.Lines)
        {
            row++;
            sheet.Cell(row, 1).Value = line.LineNo;
            sheet.Cell(row, 2).Value = line.ItemCode;
            sheet.Cell(row, 3).Value = line.ItemName;
            sheet.Cell(row, 4).Value = line.PackingFormula > 1 ? $"{line.UnitTypeName} (x{line.PackingFormula})" : line.UnitTypeName;
            sheet.Cell(row, 5).Value = line.Quantity;
            sheet.Cell(row, 6).Value = line.UnitPrice;
            sheet.Cell(row, 7).Value = line.DiscountPercent;
            sheet.Cell(row, 8).Value = line.LineDiscount;
            sheet.Cell(row, 9).Value = line.LineTotal;
            sheet.Cell(row, 10).Value = document.DocumentTypeCode switch
            {
                PurchaseDocumentTypes.Order => line.ReceivedQuantityBase,
                PurchaseDocumentTypes.Invoice => line.ReturnedQuantityBase,
                _ => line.UnitCostBase ?? 0m,
            };
            sheet.Cell(row, 11).Value = line.ExpiryDate?.ToString("dd/MM/yyyy") ?? string.Empty;
            sheet.Cell(row, 12).Value = line.Notes ?? string.Empty;
        }

        if (document.Lines.Count > 0)
        {
            sheet.Range(firstLineRow, 6, row, 6).Style.NumberFormat.Format = money;
            sheet.Range(firstLineRow, 8, row, 9).Style.NumberFormat.Format = money;
            sheet.Range(firstLineRow, 10, row, 10).Style.NumberFormat.Format =
                document.DocumentTypeCode == PurchaseDocumentTypes.Return ? "#,##0.0000" : "#,##0";
        }

        row += 2;
        // Counts are counts and money is money: "Total Items 2.00" reads as a mistake.
        var totals = new (string Label, decimal Value, bool IsMoney)[]
        {
            ("Total Items", document.TotalItems, false),
            ("Total Quantity (base units)", document.TotalQuantity, false),
            ($"Subtotal ({document.CurrencyCode})", document.Subtotal, true),
            ($"Discount ({document.CurrencyCode})", document.TotalDiscount, true),
            ($"Total ({document.CurrencyCode})", document.TotalAmount, true),
        };

        foreach (var (label, value, isMoney) in totals)
        {
            sheet.Cell(row, 8).Value = label;
            sheet.Cell(row, 8).Style.Font.Bold = true;
            sheet.Cell(row, 9).Value = value;
            sheet.Cell(row, 9).Style.NumberFormat.Format = isMoney ? money : "0";
            row++;
        }

        if (!document.IsBaseCurrency)
        {
            sheet.Cell(row, 8).Value = $"Total ({document.BaseCurrencyCode} equivalent)";
            sheet.Cell(row, 8).Style.Font.Italic = true;
            sheet.Cell(row, 9).Value = document.TotalAmountBase;
            sheet.Cell(row, 9).Style.NumberFormat.Format = "#,##0.00";
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

    private async Task<Result<PurchaseDocumentDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var document = await _documents.GetAsync(id, cancellationToken);
        return document is null
            ? Result<PurchaseDocumentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PurchaseDocumentDto>.Success(document);
    }

    private async Task<Result<PurchaseDocumentDto>> ChangeAsync(
        int id, CancellationToken cancellationToken, Func<byte[]?, Task> change,
        string? rowVersion, int userId, string verb)
    {
        try
        {
            await change(ToRowVersion(rowVersion));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PurchaseDocumentDto>(ex);
        }

        _logger.LogInformation("Purchase document {DocumentId} {Verb} by user {UserId}", id, verb, userId);

        // Re-read: posting assigns the number, writes the ledger and the costs, moves the status and
        // may close the source. The document is the server's answer, not a patch of what was sent.
        return await ReadAsync(id, cancellationToken);
    }

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified. THE MESSAGE IS ALWAYS THE PROCEDURE'S — "Line 1: 7 base
    /// units invoiced but only 6 remain on the order line." names the line and the number, and only
    /// the code is added. SOURCE_INVALID is a 409: the chain, not the request, is what refuses.
    /// </summary>
    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.PurchaseDocumentValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.PurchaseDocumentConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.PurchaseDocumentNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.PurchaseDocumentNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.PurchaseDocumentInsufficientStock => new RuleFailure(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
        SqlErrors.PurchaseDocumentMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),
        SqlErrors.PurchaseDocumentNoLines => new RuleFailure(ErrorType.Validation, exception.Message, "NO_LINES"),
        SqlErrors.PurchaseDocumentInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.PurchaseDocumentSourceInvalid => new RuleFailure(ErrorType.Conflict, exception.Message, "SOURCE_INVALID"),
        SqlErrors.PurchaseChargeAllocation => new RuleFailure(ErrorType.Validation, exception.Message, "CHARGE_ALLOCATION"),

        // Script 24: an invoice a container carries cannot be edited, cancelled or deleted from here.
        SqlErrors.ContainerInvoiceInUse => new RuleFailure(ErrorType.Conflict, exception.Message, "INVOICE_IN_USE"),

        // Script 27: imports are invoiced from their containers and carry their charges there.
        SqlErrors.PurchaseExporterReferenceRequired => new RuleFailure(ErrorType.Validation, exception.Message, "EXPORTER_REFERENCE_REQUIRED"),
        SqlErrors.PurchaseContainerLineInvalid => new RuleFailure(ErrorType.Conflict, exception.Message, "CONTAINER_LINE_INVALID"),
        SqlErrors.PurchaseChargesOnContainer => new RuleFailure(ErrorType.Conflict, exception.Message, "CHARGES_ON_CONTAINER"),
        SqlErrors.PurchaseOrderInContainers => new RuleFailure(ErrorType.Conflict, exception.Message, "PO_IN_CONTAINERS"),
        SqlErrors.ContainerLineInvoiced => new RuleFailure(ErrorType.Conflict, exception.Message, "LINE_INVOICED"),
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
