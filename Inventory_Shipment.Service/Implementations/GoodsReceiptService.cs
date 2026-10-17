using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Documents;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Goods receipts: the moment goods are counted at the gate and enter stock (scripts 64 and 65).
///
/// FIVE VERBS LIKE A DOCUMENT, NOT AN EDIT OF THE INVOICE. Posting a receipt moves stock and sets the cost every later
/// sale is valued at; the person who signs for the goods at the gate is rarely the one who posts the supplier's bill,
/// so the receipt has its own purchase.goodsreceipts.view / create / post / cancel / delete.
///
/// THE RULES ARE THE PROCEDURES': what a dialog proposes, what posting caps, why a button is disabled. This service
/// checks the permission, shapes the request into the procedures' table type, and answers their refusals as they come.
/// </summary>
public sealed class GoodsReceiptService : IGoodsReceiptService
{
    private const string NotFoundMessage = "Goods receipt not found.";
    private const string ForbiddenCode = "FORBIDDEN";

    /// <summary>SqlClient's "Execution Timeout Expired": the client stopped waiting; the database refused nothing.</summary>
    private const int CommandTimeoutNumber = -2;

    /// <summary>
    /// What a posting or a cancel that ran out of time answers: 63010's own sentence. Posting and cancelling wait for the
    /// matching lock (up to 60 s, purchase.usp_GoodsReceipt_LockMatching), so a call that times out was almost always
    /// waiting for another user's matching - a 409 to try again, not a 500.
    /// </summary>
    private const string MatcherBusyMessage =
        "Goods receipts and invoices are being matched for another user. Try again in a moment.";

    private readonly IGoodsReceiptRepository _receipts;
    private readonly ILogger<GoodsReceiptService> _logger;

    public GoodsReceiptService(IGoodsReceiptRepository receipts, ILogger<GoodsReceiptService> logger)
    {
        _receipts = receipts;
        _logger = logger;
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    private static Result ForbiddenResult(string permission)
        => Result.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<GoodsReceiptListResult>> SearchAsync(
        GoodsReceiptQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsView))
        {
            return Forbidden<GoodsReceiptListResult>(Permissions.Purchase.GoodsReceiptsView);
        }

        var (items, totalCount, totals) = await _receipts.SearchAsync(query, cancellationToken);

        return Result<GoodsReceiptListResult>.Success(new GoodsReceiptListResult
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
            Totals = totals,
        });
    }

    public async Task<Result<GoodsReceiptWaitingDto>> WaitingAsync(
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => permissions.Contains(Permissions.Purchase.GoodsReceiptsView)
            ? Result<GoodsReceiptWaitingDto>.Success(await _receipts.WaitingCountAsync(userId, cancellationToken))
            : Forbidden<GoodsReceiptWaitingDto>(Permissions.Purchase.GoodsReceiptsView);

    public Task<GoodsReceiptSwitchDto> SwitchAsync(CancellationToken cancellationToken = default)
        => _receipts.SwitchAsync(cancellationToken);

    public async Task<Result<GoodsReceiptDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => permissions.Contains(Permissions.Purchase.GoodsReceiptsView)
            ? await ReadAsync(id, cancellationToken)
            : Forbidden<GoodsReceiptDto>(Permissions.Purchase.GoodsReceiptsView);

    /* ── a draft ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// A draft of any source. EVERY LINE IS PASSED AS IT COMES, NEVER DROPPED: a line of 0 that is neither a container's
    /// (the difference is settled) nor "Nothing more will come" on a line of an order is refused by usp_GoodsReceipt_Save
    /// with its "Line N (item)" sentence. Dropping it silently lost the line from an order or invoice draft (which has no
    /// "+ Add line") and shifted the numbers the procedure's sentences give, so "Line 2" pointed at another row.
    /// </summary>
    public async Task<Result<GoodsReceiptDto>> SaveDraftAsync(
        int? id, GoodsReceiptSaveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate))
        {
            return Forbidden<GoodsReceiptDto>(Permissions.Purchase.GoodsReceiptsCreate);
        }

        if (request.SourceKind is { Length: > 0 } kind && GoodsReceiptSourceKinds.Normalize(kind) is null)
        {
            return Result<GoodsReceiptDto>.Failure(
                ErrorType.Validation, "sourceKind must be Container, Order, Invoice or Manual.", "VALIDATION");
        }

        int savedId;
        try
        {
            savedId = await _receipts.SaveAsync(id, request, request.Lines, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<GoodsReceiptDto>(ex);
        }

        _logger.LogInformation("Goods receipt {GoodsReceiptId} saved by user {UserId}", savedId, userId);
        return await ReadAsync(savedId, cancellationToken);
    }

    public async Task<Result> DeleteAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsDelete))
        {
            return ForbiddenResult(Permissions.Purchase.GoodsReceiptsDelete);
        }

        try
        {
            await _receipts.DeleteAsync(id, ToRowVersion(rowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Goods receipt {GoodsReceiptId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /* ── posting and cancelling ───────────────────────────────────────────────────────────────── */

    public async Task<Result<GoodsReceiptDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsPost))
        {
            return Forbidden<GoodsReceiptDto>(Permissions.Purchase.GoodsReceiptsPost);
        }

        var posted = await PostCoreAsync(id, ToRowVersion(rowVersion), userId, cancellationToken);
        if (posted.IsFailure)
        {
            return Result<GoodsReceiptDto>.Failure(posted.ErrorType, posted.Error ?? string.Empty, posted.Code ?? "ERROR");
        }

        // Re-read: posting gives the number, writes the ledger and the costs, counts the order's received pieces and offloads the
        // container. The document is the server's answer, not a patch of what was sent.
        return await ReadAsync(id, cancellationToken);
    }

    public async Task<Result<IReadOnlyList<BulkActionItemResult>>> PostManyAsync(
        IReadOnlyList<int> ids, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsPost))
        {
            return Forbidden<IReadOnlyList<BulkActionItemResult>>(Permissions.Purchase.GoodsReceiptsPost);
        }

        var result = await BulkDocumentActions.RunAsync(ids, id => PostCoreAsync(id, null, userId, cancellationToken));
        return Result<IReadOnlyList<BulkActionItemResult>>.Success(result.Results);
    }

    public async Task<Result<GoodsReceiptDto>> CancelAsync(
        int id, GoodsReceiptCancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCancel))
        {
            return Forbidden<GoodsReceiptDto>(Permissions.Purchase.GoodsReceiptsCancel);
        }

        try
        {
            await _receipts.CancelAsync(id, request.Reason.Trim(), ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<GoodsReceiptDto>(ex);
        }
        catch (SqlException ex) when (ex.Number == CommandTimeoutNumber)
        {
            _logger.LogWarning(ex, "Cancelling goods receipt {GoodsReceiptId} ran out of time (waiting for the matching lock)", id);
            return Result<GoodsReceiptDto>.Failure(ErrorType.Conflict, MatcherBusyMessage, "CONFLICT");
        }

        _logger.LogInformation("Goods receipt {GoodsReceiptId} cancelled by user {UserId}", id, userId);
        return await ReadAsync(id, cancellationToken);
    }

    /// <summary>
    /// Posts one draft; its value is the number it was given. A posting that runs out of time is a refusal like the
    /// others (409, 63010's sentence), not a 500: the single post answers it, "Post selected" goes on with the next
    /// draft, and "Create and post" keeps the draft and says why it was not posted.
    /// </summary>
    private async Task<Result<string?>> PostCoreAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken)
    {
        string? number;
        try
        {
            number = await _receipts.PostAsync(id, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<string?>(ex);
        }
        catch (SqlException ex) when (ex.Number == CommandTimeoutNumber)
        {
            _logger.LogWarning(ex, "Posting goods receipt {GoodsReceiptId} ran out of time (waiting for the matching lock)", id);
            return Result<string?>.Failure(ErrorType.Conflict, MatcherBusyMessage, "CONFLICT");
        }

        _logger.LogInformation("Goods receipt {GoodsReceiptId} posted as {DocumentNumber} by user {UserId}", id, number, userId);
        return Result<string?>.Success(number);
    }

    /* ── "Receive goods..." ───────────────────────────────────────────────────────────────────── */

    public async Task<Result<ReceivableDto>> ReceivableAsync(
        ReceivableQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate))
        {
            return Forbidden<ReceivableDto>(Permissions.Purchase.GoodsReceiptsCreate);
        }

        var asked = new[] { query.PurchaseOrderId, query.InvoiceId, query.SupplierId, query.ContainerId }.Count(v => v is not null);
        if (asked != 1)
        {
            return Result<ReceivableDto>.Failure(
                ErrorType.Validation, "Give one of purchaseOrderId, invoiceId, supplierId or containerId.", "VALIDATION");
        }

        if (query.PurchaseOrderId is { } orderId)
        {
            var order = await _receipts.OrderReceivableAsync(orderId, null, cancellationToken);
            return order.Documents.Count == 0
                ? Result<ReceivableDto>.Failure(ErrorType.NotFound, "Purchase order not found.", "NOT_FOUND")
                : Result<ReceivableDto>.Success(order);
        }

        if (query.SupplierId is { } supplierId)
        {
            return Result<ReceivableDto>.Success(await _receipts.OrderReceivableAsync(null, supplierId, cancellationToken));
        }

        if (query.InvoiceId is { } invoiceId)
        {
            var invoice = await _receipts.InvoiceReceivableAsync(invoiceId, cancellationToken);
            return invoice is null
                ? Result<ReceivableDto>.Failure(ErrorType.NotFound, "Purchase invoice not found.", "NOT_FOUND")
                : Result<ReceivableDto>.Success(invoice);
        }

        var container = await _receipts.ContainerReceivableAsync(query.ContainerId!.Value, cancellationToken);
        return container is null
            ? Result<ReceivableDto>.Failure(ErrorType.NotFound, "Container not found.", "NOT_FOUND")
            : Result<ReceivableDto>.Success(container);
    }

    public async Task<Result<IReadOnlyList<ReceivableContainerDto>>> ReceivableContainersAsync(
        ReceivableContainersQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate)
            ? Result<IReadOnlyList<ReceivableContainerDto>>.Success(await _receipts.ReceivableContainersAsync(query, cancellationToken))
            : Forbidden<IReadOnlyList<ReceivableContainerDto>>(Permissions.Purchase.GoodsReceiptsCreate);

    /// <summary>
    /// "Receive goods..." on a purchase order, posted at once when asked. The lines come in PIECES (quantityBase): each
    /// goes as the order line's item in its base unit, and the procedure writes it in the order line's unit when the
    /// pieces divide by its packing. An id that is not a line of the order is refused by the procedure, by line.
    /// </summary>
    public async Task<Result<GoodsReceiptCreatedDto>> ReceiveFromOrderAsync(
        ReceiveFromOrderRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (RefuseCreate(request.Post, permissions) is { } refusal)
        {
            return refusal;
        }

        var given = request.Lines ?? [];
        var units = await _receipts.LineItemUnitsAsync(
            ReceivableLineTable.PurchaseDocumentLine, given.Select(l => l.PoLineId).ToList(), cancellationToken);

        var lines = given.Select(l => new GoodsReceiptSaveLineRequest
        {
            ItemId = units.GetValueOrDefault(l.PoLineId)?.ItemId ?? 0,
            ItemUnitId = units.GetValueOrDefault(l.PoLineId)?.BaseUnitId ?? 0,
            Quantity = l.QuantityBase,
            WarehouseId = l.WarehouseId,
            PoLineId = l.PoLineId,
            CloseShort = l.CloseShort,
            VarianceReasonCode = l.ReasonCode,
            VarianceReason = l.Reason,
            ExpiryDate = l.ExpiryDate,
            Notes = l.Notes,
        }).ToList();

        return await CreateAsync(
            () => _receipts.CreateFromOrderAsync(
                request.PurchaseOrderId, lines, request.DocumentDate, request.SupplierReference, request.WarehouseId,
                request.Notes, userId, cancellationToken),
            request.Post, userId, $"order {request.PurchaseOrderId}", cancellationToken);
    }

    /// <summary>"Receive goods..." on a posted purchase invoice, for its lines not linked to a container; as the order's.</summary>
    public async Task<Result<GoodsReceiptCreatedDto>> ReceiveFromInvoiceAsync(
        ReceiveFromInvoiceRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (RefuseCreate(request.Post, permissions) is { } refusal)
        {
            return refusal;
        }

        var given = request.Lines ?? [];
        var units = await _receipts.LineItemUnitsAsync(
            ReceivableLineTable.PurchaseDocumentLine, given.Select(l => l.InvoiceLineId).ToList(), cancellationToken);

        var lines = given.Select(l => new GoodsReceiptSaveLineRequest
        {
            ItemId = units.GetValueOrDefault(l.InvoiceLineId)?.ItemId ?? 0,
            ItemUnitId = units.GetValueOrDefault(l.InvoiceLineId)?.BaseUnitId ?? 0,
            Quantity = l.QuantityBase,
            WarehouseId = l.WarehouseId,
            InvoiceLineId = l.InvoiceLineId,
            CloseShort = l.CloseShort,
            VarianceReasonCode = l.ReasonCode,
            VarianceReason = l.Reason,
            ExpiryDate = l.ExpiryDate,
            Notes = l.Notes,
        }).ToList();

        return await CreateAsync(
            () => _receipts.CreateFromInvoiceAsync(
                request.InvoiceId, lines, request.DocumentDate, request.SupplierReference, request.WarehouseId,
                request.Notes, userId, cancellationToken),
            request.Post, userId, $"invoice {request.InvoiceId}", cancellationToken);
    }

    /// <summary>
    /// "Receive goods..." on a container (status 2–5, no receipt yet): the draft holds every container line, in pieces,
    /// as loaded unless the request counts them differently (with a reason). Posted at once when asked.
    /// </summary>
    public async Task<Result<GoodsReceiptCreatedDto>> ReceiveContainerAsync(
        ReceiveContainerRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (RefuseCreate(request.Post, permissions) is { } refusal)
        {
            return refusal;
        }

        var given = request.Lines ?? [];
        var units = await _receipts.LineItemUnitsAsync(
            ReceivableLineTable.ContainerLine, given.Select(l => l.ContainerLineId).ToList(), cancellationToken);

        var lines = given.Select(l => new GoodsReceiptSaveLineRequest
        {
            ItemId = units.GetValueOrDefault(l.ContainerLineId)?.ItemId ?? 0,
            ItemUnitId = units.GetValueOrDefault(l.ContainerLineId)?.BaseUnitId ?? 0,
            Quantity = l.QuantityBase,
            ContainerLineId = l.ContainerLineId,
            VarianceReasonCode = l.VarianceReasonCode,
            VarianceReason = l.VarianceReason,
            ExpiryDate = l.ExpiryDate,
            Notes = l.Notes,
        }).ToList();

        return await CreateAsync(
            () => _receipts.CreateForContainerAsync(
                request.ContainerId, lines, request.DocumentDate, request.WarehouseId, userId, cancellationToken),
            request.Post, userId, $"container {request.ContainerId}", cancellationToken);
    }

    /// <summary>Creating needs create; creating and posting needs post too - checked before anything is written.</summary>
    private static Result<GoodsReceiptCreatedDto>? RefuseCreate(bool post, IReadOnlySet<string> permissions)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate))
        {
            return Forbidden<GoodsReceiptCreatedDto>(Permissions.Purchase.GoodsReceiptsCreate);
        }

        return post && !permissions.Contains(Permissions.Purchase.GoodsReceiptsPost)
            ? Forbidden<GoodsReceiptCreatedDto>(Permissions.Purchase.GoodsReceiptsPost)
            : null;
    }

    /// <summary>
    /// Creates the draft, then posts it when asked. A REFUSED POSTING LEAVES THE DRAFT and is not a failure of the
    /// call: the draft exists, the answer says why it was not posted, and the page opens it to fix what is wrong.
    /// </summary>
    private async Task<Result<GoodsReceiptCreatedDto>> CreateAsync(
        Func<Task<int>> create, bool post, int userId, string source, CancellationToken cancellationToken)
    {
        int id;
        try
        {
            id = await create();
        }
        catch (BusinessRuleException ex)
        {
            return Failure<GoodsReceiptCreatedDto>(ex);
        }

        _logger.LogInformation("Draft goods receipt {GoodsReceiptId} created from {Source} by user {UserId}", id, source, userId);

        if (!post)
        {
            return Result<GoodsReceiptCreatedDto>.Success(new GoodsReceiptCreatedDto
            {
                Id = id,
                Status = GoodsReceiptStatus.Draft,
                Message = "Draft goods receipt created.",
            });
        }

        var posted = await PostCoreAsync(id, null, userId, cancellationToken);
        return Result<GoodsReceiptCreatedDto>.Success(posted.IsSuccess
            ? new GoodsReceiptCreatedDto
            {
                Id = id,
                DocumentNumber = posted.Value,
                Status = GoodsReceiptStatus.Posted,
                Message = $"Goods receipt {posted.Value} posted.",
            }
            : new GoodsReceiptCreatedDto
            {
                Id = id,
                Status = GoodsReceiptStatus.Draft,
                Message = $"Draft goods receipt created; it was not posted: {posted.Error}",
                PostRefusal = new GoodsReceiptRefusalDto { Code = posted.Code ?? "ERROR", Message = posted.Error ?? string.Empty },
            });
    }

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    /// <summary>Files as on the purchase documents: added, edited and deleted with the create right, in any status.</summary>
    public async Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate))
        {
            return Forbidden<int>(Permissions.Purchase.GoodsReceiptsCreate);
        }

        try
        {
            return Result<int>.Success(
                await _receipts.AddFileAsync(id, fileName, contentType, content, fields, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }
    }

    public async Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int id, int? attachmentTypeId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsView))
        {
            return Forbidden<IReadOnlyList<DocumentFileDto>>(Permissions.Purchase.GoodsReceiptsView);
        }

        if (await _receipts.GetStubAsync(id, cancellationToken) is null)
        {
            return Result<IReadOnlyList<DocumentFileDto>>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        return Result<IReadOnlyList<DocumentFileDto>>.Success(
            await _receipts.ListFilesAsync(id, attachmentTypeId, cancellationToken: cancellationToken));
    }

    public async Task<Result<GoodsReceiptFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsView))
        {
            return Forbidden<GoodsReceiptFileContent>(Permissions.Purchase.GoodsReceiptsView);
        }

        var file = await _receipts.GetFileAsync(fileId, cancellationToken);

        // Checked against the receipt in the route: file ids are sequential across every receipt.
        return file is null || file.DocumentId != id
            ? Result<GoodsReceiptFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<GoodsReceiptFileContent>.Success(file);
    }

    public async Task<Result<DocumentFileDto>> UpdateFileAsync(
        int id, int fileId, DocumentFileEdit edit, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate))
        {
            return Forbidden<DocumentFileDto>(Permissions.Purchase.GoodsReceiptsCreate);
        }

        if ((await _receipts.ListFilesAsync(id, fileId: fileId, cancellationToken: cancellationToken)).Count == 0)
        {
            return Result<DocumentFileDto>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            var file = await _receipts.UpdateFileAsync(fileId, edit, userId, cancellationToken);
            return file is null
                ? Result<DocumentFileDto>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
                : Result<DocumentFileDto>.Success(file);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<DocumentFileDto>(ex);
        }
    }

    public async Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate))
        {
            return ForbiddenResult(Permissions.Purchase.GoodsReceiptsCreate);
        }

        var file = await _receipts.GetFileAsync(fileId, cancellationToken);
        if (file is null || file.DocumentId != id)
        {
            return Result.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            await _receipts.DeleteFileAsync(fileId, userId, cancellationToken);
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

        return Result<(byte[], string)>.Success((BuildWorkbook(read.Value), ExportFileName(read.Value)));
    }

    /// <summary>"GRN-BR-002-000001.xlsx" - without doubling the prefix of a number that starts with it; a draft has none.</summary>
    internal static string ExportFileName(GoodsReceiptDto receipt)
    {
        if (string.IsNullOrWhiteSpace(receipt.DocumentNumber))
        {
            return $"GRN-DRAFT-{receipt.Id}.xlsx";
        }

        var number = receipt.DocumentNumber.Trim();
        return (number.StartsWith("GRN-", StringComparison.OrdinalIgnoreCase) ? number : "GRN-" + number) + ".xlsx";
    }

    /// <summary>
    /// The receipt as the warehouse files it: where the goods came from and where they went in the header, then per
    /// line what was expected, what arrived, the difference and its reason, and what the goods cost now.
    /// </summary>
    internal static byte[] BuildWorkbook(GoodsReceiptDto receipt)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Goods Receipt");
        var currency = string.IsNullOrWhiteSpace(receipt.BaseCurrencyCode) ? "base" : receipt.BaseCurrencyCode;
        const string pieces = "#,##0";
        const string money = "#,##0.00";
        const string unitCost = "#,##0.0000";

        sheet.Cell(1, 1).Value = $"Goods Receipt {receipt.DocumentNumber ?? "(draft)"}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var source = receipt.SourceKind switch
        {
            GoodsReceiptSourceKinds.Container => $"Container {receipt.ContainerRef}",
            GoodsReceiptSourceKinds.Order => $"Purchase order {receipt.PurchaseOrderNumber}",
            GoodsReceiptSourceKinds.Invoice => $"Purchase invoice {receipt.PurchaseInvoiceNumber}",
            _ => "Without an order",
        };

        var header = new List<(string Label, string Value)>
        {
            ("Goods Receipt No.", receipt.DocumentNumber ?? "DRAFT"),
            ("Status", receipt.StatusName),
            ("Date Received", receipt.DocumentDate.ToString("dd/MM/yyyy")),
            ("Source", receipt.IsAuto && receipt.MovementNo is not null ? $"{source} (created when {receipt.MovementNo} was completed)" : source),
            ("Branch", Joined(receipt.BranchCode, receipt.BranchName)),
            ("Receive Into", receipt.WarehouseId is null ? "(to choose)" : Joined(receipt.WarehouseCode, receipt.WarehouseName)),
            ("Supplier", Joined(receipt.SupplierCode, receipt.SupplierDisplayName ?? receipt.SupplierName)),
        };

        if (receipt.ContainerId is not null)
        {
            header.Add(("Container", string.IsNullOrWhiteSpace(receipt.ContainerNo)
                ? receipt.ContainerRef ?? string.Empty
                : $"{receipt.ContainerRef} ({receipt.ContainerNo})"));
        }

        if (receipt.PurchaseOrderNumber is not null)
        {
            header.Add(("Purchase Order", receipt.PurchaseOrderNumber));
        }

        if (receipt.PurchaseInvoiceNumber is not null)
        {
            header.Add(("Purchase Invoice", receipt.PurchaseInvoiceNumber));
        }

        if (receipt.DeliveredDate is { } delivered)
        {
            header.Add(("Delivered", $"{delivered:dd/MM/yyyy} {receipt.DeliveryPlaceName} ({receipt.DeliveryMovementNo})".Trim()));
        }

        header.Add(("Delivery Note No.", receipt.SupplierReference ?? string.Empty));
        header.Add(("Notes", receipt.Notes ?? string.Empty));

        if (receipt.PostedAtUtc is { } postedAt)
        {
            header.Add(("Posted", $"{postedAt:dd/MM/yyyy} {receipt.PostedByName}".Trim()));
        }

        if (receipt.CancelledAtUtc is { } cancelledAt)
        {
            header.Add(("Cancelled", $"{cancelledAt:dd/MM/yyyy} {receipt.CancelledByName}: {receipt.CancelReason}".Trim()));
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
            "#", "Item Code", "Item Name", "Unit", "Warehouse", "Source", "Expected (pcs)", "Received (pcs)", "Difference",
            "Reason", "Settled Short (pcs)", $"Cost per Piece ({currency})", $"Value ({currency})", "Cost Source",
            "Invoiced (pcs)", "Expiry", "Notes",
        ];
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(row, i + 1).Value = columns[i];
        }

        var headerRange = sheet.Range(row, 1, row, columns.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        headerRange.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var firstLineRow = row + 1;
        foreach (var line in receipt.Lines)
        {
            row++;
            sheet.Cell(row, 1).Value = line.LineNumber;
            sheet.Cell(row, 2).Value = line.ItemCode;
            sheet.Cell(row, 3).Value = line.ItemName;
            sheet.Cell(row, 4).Value = line.PackingFormula > 1 ? $"{line.UnitTypeName} (x{line.PackingFormula})" : line.UnitTypeName ?? string.Empty;
            sheet.Cell(row, 5).Value = line.WarehouseCode ?? string.Empty;
            sheet.Cell(row, 6).Value = LineSource(receipt, line);
            sheet.Cell(row, 7).Value = line.ExpectedQuantityBase is { } expected ? expected : Blank.Value;
            sheet.Cell(row, 8).Value = line.QuantityBase;
            // Received - expected on every line that expects something, as the receipt page and the print page show it
            // (a partial receipt of an order line too: 60 of 100 is -40). Whether the missing pieces are settled short
            // is the "Settled Short (pcs)" column's business, not this one's. A line without an order expects nothing.
            sheet.Cell(row, 9).Value = line.ExpectedQuantityBase is { } expectedPieces ? line.QuantityBase - expectedPieces : Blank.Value;
            sheet.Cell(row, 10).Value = LineReason(line);
            sheet.Cell(row, 11).Value = line.SettledShortBase;
            sheet.Cell(row, 12).Value = line.UnitCostBase is { } cost ? cost : Blank.Value;
            sheet.Cell(row, 13).Value = line.ValueBase is { } value ? value : Blank.Value;
            sheet.Cell(row, 14).Value = line.IsCostEstimate
                ? (line.CostSourceName is null ? "Estimate" : $"{line.CostSourceName} (est.)")
                : line.CostSourceName ?? string.Empty;
            sheet.Cell(row, 15).Value = line.InvoicedBase;
            sheet.Cell(row, 16).Value = line.ExpiryDate?.ToString("dd/MM/yyyy") ?? string.Empty;
            sheet.Cell(row, 17).Value = line.Notes ?? string.Empty;
        }

        if (receipt.Lines.Count > 0)
        {
            sheet.Range(firstLineRow, 7, row, 9).Style.NumberFormat.Format = pieces;
            sheet.Range(firstLineRow, 11, row, 11).Style.NumberFormat.Format = pieces;
            sheet.Range(firstLineRow, 12, row, 12).Style.NumberFormat.Format = unitCost;
            sheet.Range(firstLineRow, 13, row, 13).Style.NumberFormat.Format = money;
            sheet.Range(firstLineRow, 15, row, 15).Style.NumberFormat.Format = pieces;
        }

        row += 2;
        // Pieces are pieces and money is money: "Received 82.00" reads as a mistake.
        var totals = new List<(string Label, decimal Value, bool IsMoney)>
        {
            ("Expected (pcs)", receipt.TotalExpectedBase, false),
            ("Received (pcs)", receipt.TotalReceivedBase, false),
            ("Settled short (pcs)", receipt.TotalShortBase, false),
            ("Invoiced (pcs)", receipt.TotalInvoicedBase, false),
        };

        if (receipt.Status != GoodsReceiptStatus.Draft)
        {
            totals.Add(($"Value at receipt ({currency})", receipt.ValueAtReceiptBase, true));
        }

        totals.Add((receipt.IsValueEstimate ? $"Value, estimated ({currency})" : $"Current value ({currency})", receipt.CurrentValueBase, true));

        foreach (var (label, value, isMoney) in totals)
        {
            sheet.Cell(row, 12).Value = label;
            sheet.Cell(row, 12).Style.Font.Bold = true;
            sheet.Cell(row, 13).Value = value;
            sheet.Cell(row, 13).Style.NumberFormat.Format = isMoney ? money : pieces;
            row++;
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(3).Width = 36;
        sheet.Column(10).Width = 36;
        sheet.Column(17).Width = 30;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string Joined(string? code, string? name)
        => string.Join(" - ", new[] { code, name }.Where(s => !string.IsNullOrWhiteSpace(s)));

    /// <summary>Where a line comes from: its container line, invoice line or order line.</summary>
    private static string LineSource(GoodsReceiptDto receipt, GoodsReceiptLineDto line)
    {
        if (line.ContainerLineId is not null)
        {
            return $"{receipt.ContainerRef} line {line.ContainerLineNumber}" + (line.OrderNumber is null ? string.Empty : $" ({line.OrderNumber})");
        }

        if (line.InvoiceLineId is not null)
        {
            return $"{line.InvoiceNumber} line {line.InvoiceLineNumber}";
        }

        return line.PoLineId is not null ? $"{line.OrderNumber} line {line.PoLineNumber}" : "Without an order";
    }

    private static string LineReason(GoodsReceiptLineDto line)
    {
        var reason = line.VarianceReasonName ?? GoodsReceiptReasonCodes.Name(line.VarianceReasonCode);
        var text = string.Join(": ", new[] { reason, line.VarianceReason }.Where(s => !string.IsNullOrWhiteSpace(s)));
        return line.CloseShort ? string.Join(" - ", new[] { "Nothing more will come", text }.Where(s => s.Length > 0)) : text;
    }

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private async Task<Result<GoodsReceiptDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var receipt = await _receipts.GetAsync(id, cancellationToken);
        return receipt is null
            ? Result<GoodsReceiptDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<GoodsReceiptDto>.Success(receipt);
    }

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified. THE MESSAGE IS ALWAYS THE PROCEDURE'S - "Line 2 (MOTO-01): received 90 but
    /// only 84 were loaded." names the line and the numbers - and only the code is added. 400 for what the request got
    /// wrong (63000, 63009, 63011, 63012), 404 for 63006, 409 for the state of the world (a draft changed by someone
    /// else, stock already used, a cost adjusted since, a container moving or closed, a receipt already there).
    /// The container and purchase procedures a posting calls answer with their own blocks: classified as their services do.
    /// </summary>
    internal static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.GoodsReceiptValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.GoodsReceiptConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.GoodsReceiptNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.GoodsReceiptNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.GoodsReceiptInsufficientStock => new RuleFailure(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
        SqlErrors.GoodsReceiptCostAdjusted => new RuleFailure(ErrorType.Conflict, exception.Message, "COST_ADJUSTED"),
        SqlErrors.GoodsReceiptNothingToReceive => new RuleFailure(ErrorType.Validation, exception.Message, "NOTHING_TO_RECEIVE"),
        SqlErrors.GoodsReceiptInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.GoodsReceiptMoreThanRemains => new RuleFailure(ErrorType.Validation, exception.Message, "MORE_THAN_REMAINS"),
        SqlErrors.GoodsReceiptAttachmentType => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.GoodsReceiptContainerHasReceipt => new RuleFailure(ErrorType.Conflict, exception.Message, "HAS_GOODS_RECEIPT"),
        SqlErrors.StockDocumentInsufficientStock => new RuleFailure(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
        >= SqlErrors.ContainerValidation and <= SqlErrors.LogisticsValidation + 999 => FromLogistics(exception),
        >= SqlErrors.PurchaseDocumentValidation and <= SqlErrors.PurchaseDocumentValidation + 999 => FromPurchase(exception),
        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
    };

    private static RuleFailure FromLogistics(BusinessRuleException exception)
    {
        var failure = LogisticsRuleFailures.Describe(exception);
        return new RuleFailure(failure.Type, failure.Message, failure.Code);
    }

    private static RuleFailure FromPurchase(BusinessRuleException exception)
    {
        var failure = PurchaseDocumentService.Describe(exception);
        return new RuleFailure(failure.Type, failure.Message, failure.Code);
    }

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

    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);
}
