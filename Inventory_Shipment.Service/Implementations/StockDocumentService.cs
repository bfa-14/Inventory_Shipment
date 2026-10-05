using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Documents;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class StockDocumentService : IStockDocumentService
{
    private const string NotFoundMessage = "Document not found.";
    private const string ForbiddenMessage = "You do not have permission for this action.";

    /// <summary>What a caller is trying to do, which is what decides WHICH permission is looked for.</summary>
    private enum DocumentAction
    {
        View,
        Create,
        Post,
        Cancel,
        Delete,
    }

    private readonly IStockDocumentRepository _documents;
    private readonly ILogger<StockDocumentService> _logger;

    public StockDocumentService(IStockDocumentRepository documents, ILogger<StockDocumentService> logger)
    {
        _documents = documents;
        _logger = logger;
    }

    /* ── configuration and lookups: readable by any signed-in user ────────────────────────────── */

    public async Task<Result<IReadOnlyList<DocumentTypeDto>>> GetDocumentTypesAsync(CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<DocumentTypeDto>>.Success(await _documents.GetDocumentTypesAsync(cancellationToken));

    public async Task<Result<IReadOnlyList<StockReasonDto>>> GetStockReasonsAsync(
        short? direction, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<StockReasonDto>>.Success(await _documents.GetStockReasonsAsync(direction, cancellationToken));

    public async Task<Result<decimal>> GetOnHandAsync(int itemId, int warehouseId, CancellationToken cancellationToken = default)
        => Result<decimal>.Success(await _documents.GetOnHandAsync(itemId, warehouseId, cancellationToken));

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<StockDocumentListDto>>> SearchAsync(
        StockDocumentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!StockDocumentTypes.IsKnown(query.DocumentTypeCode))
        {
            return Result<PagedResult<StockDocumentListDto>>.Failure(
                ErrorType.Validation, "documentTypeCode must be INV_IN or INV_OUT.", "VALIDATION");
        }

        if (!Allows(permissions, query.DocumentTypeCode!, DocumentAction.View))
        {
            return Result<PagedResult<StockDocumentListDto>>.Failure(ErrorType.Forbidden, ForbiddenMessage, "FORBIDDEN");
        }

        var (items, totalCount) = await _documents.SearchAsync(query, cancellationToken);

        return Result<PagedResult<StockDocumentListDto>>.Success(new PagedResult<StockDocumentListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<StockDocumentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => await ReadAsync(id, permissions, DocumentAction.View, cancellationToken);

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<StockDocumentDto>> SaveDraftAsync(
        int? id, SaveStockDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!StockDocumentTypes.IsKnown(request.DocumentTypeCode))
        {
            return Failure("documentTypeCode must be INV_IN or INV_OUT.", ErrorType.Validation, "VALIDATION");
        }

        if (!Allows(permissions, request.DocumentTypeCode, DocumentAction.Create))
        {
            return Failure(ForbiddenMessage, ErrorType.Forbidden, "FORBIDDEN");
        }

        /* AN EXISTING DOCUMENT IS CHECKED AGAINST ITS OWN TYPE AS WELL. Without this, somebody holding
           only stockin.create could aim a PUT carrying documentTypeCode INV_IN at an INV_OUT document
           and pass the check above. The procedure would refuse to change the type, but the request
           should never get that far. */
        if (id is { } existingId)
        {
            var existing = await _documents.GetAsync(existingId, cancellationToken);
            if (existing is null)
            {
                return Failure(NotFoundMessage, ErrorType.NotFound, "NOT_FOUND");
            }

            if (!Allows(permissions, existing.DocumentTypeCode, DocumentAction.Create))
            {
                return Failure(ForbiddenMessage, ErrorType.Forbidden, "FORBIDDEN");
            }
        }

        int savedId;
        try
        {
            savedId = await _documents.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Stock document {DocumentId} ({TypeCode}) saved by user {UserId}",
            savedId, request.DocumentTypeCode, userId);

        return await ReadAsync(savedId, permissions, DocumentAction.View, cancellationToken);
    }

    public async Task<Result<StockDocumentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => await ChangeAsync(id, permissions, DocumentAction.Post, cancellationToken,
            (documentId, version) => _documents.PostAsync(documentId, version, userId, cancellationToken),
            rowVersion, userId, "posted");

    public async Task<Result<StockDocumentDto>> CancelAsync(
        int id, CancelStockDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => await ChangeAsync(id, permissions, DocumentAction.Cancel, cancellationToken,
            (documentId, version) => _documents.CancelAsync(documentId, request.Reason, version, userId, cancellationToken),
            request.RowVersion, userId, "cancelled");

    public async Task<Result<DocumentTypeDto>> UpdateDocumentTypeAsync(
        int id, UpdateDocumentTypeRequest request, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _documents.UpdateDocumentTypeAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result<DocumentTypeDto>.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Document type {DocumentTypeId} configured by user {UserId}", id, userId);

        // Re-read: the procedure trims, defaults and stamps a new row version, and the page needs all three.
        var types = await _documents.GetDocumentTypesAsync(cancellationToken);
        var type = types.FirstOrDefault(t => t.Id == id);
        return type is null
            ? Result<DocumentTypeDto>.Failure(ErrorType.NotFound, "Document type not found.", "NOT_FOUND")
            : Result<DocumentTypeDto>.Success(type);
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
    /// The imported file's lines, saved as ONE document whatever warehouses they name.
    ///
    /// THE WAREHOUSE IS A LINE'S, so a file naming several no longer becomes several documents — it
    /// becomes one document whose rows each keep the warehouse the file gave them. The header's
    /// warehouse is left for the database to take from the first line.
    ///
    /// A REFUSED POSTING LEAVES THE DRAFT IN PLACE and is reported in Failed: the lines cost somebody
    /// a file and are worth keeping. The result still carries a list because the shape is shared with
    /// the other families and with the page that reads it; it now holds at most one document.
    /// </summary>
    public async Task<Result<ImportCreateResult>> ImportCreateAsync(
        ImportCreateStockDocumentsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!StockDocumentTypes.IsKnown(request.DocumentTypeCode))
        {
            return Result<ImportCreateResult>.Failure(ErrorType.Validation, "documentTypeCode must be INV_IN or INV_OUT.", "VALIDATION");
        }

        if (!Allows(permissions, request.DocumentTypeCode, DocumentAction.Create)
            || (request.PostImmediately && !Allows(permissions, request.DocumentTypeCode, DocumentAction.Post)))
        {
            return Result<ImportCreateResult>.Failure(ErrorType.Forbidden, ForbiddenMessage, "FORBIDDEN");
        }

        if (request.Lines.Count == 0)
        {
            return Result<ImportCreateResult>.Failure(ErrorType.Validation, "The file has no lines to import.", "NO_LINES");
        }

        var isIn = string.Equals(request.DocumentTypeCode, StockDocumentTypes.In, StringComparison.OrdinalIgnoreCase);
        var documents = new List<ImportCreateDocument>();
        var failed = new List<ImportCreateFailure>();
        var posted = 0;

        var warehouseCount = request.Lines.Select(line => line.WarehouseId).Distinct().Count();

        var draft = new SaveStockDocumentRequest
        {
            DocumentTypeCode = request.DocumentTypeCode,
            DocumentDate = request.DocumentDate,
            BranchId = request.BranchId,
            // Left for the database, which takes the first line's: the header warehouse is only a label.
            WarehouseId = null,
            ReasonId = request.ReasonId,
            ReferenceNo = request.ReferenceNo,
            Notes = request.Notes,
            Lines = request.Lines.Select((line, index) => new SaveStockDocumentLineRequest
            {
                LineNo = index + 1,
                ItemId = line.ItemId,
                ItemUnitId = line.ItemUnitId,
                // THE ROW'S OWN WAREHOUSE, the one the file named on that row.
                WarehouseId = line.WarehouseId,
                ExpiryDate = line.ExpiryDate,
                Quantity = line.Quantity,
                // The file's price column is the unit cost on an In; an Out takes the average and ignores it.
                UnitCost = isIn ? line.UnitPrice ?? 0 : null,
                Notes = line.Notes,
            }).ToList(),
        };

        var saved = await SaveDraftAsync(null, draft, userId, permissions, cancellationToken);
        if (saved.IsFailure || saved.Value is null)
        {
            failed.Add(new ImportCreateFailure
            {
                Code = saved.Code ?? "ERROR",
                Message = saved.Error ?? "The document could not be created.",
            });
        }
        else
        {
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
                        WarehouseId = document.WarehouseId,
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
                WarehouseId = document.WarehouseId,
                WarehouseName = document.WarehouseName,
                WarehouseCount = warehouseCount,
                LineCount = document.Lines.Count,
                Status = document.Status,
            });
        }

        _logger.LogInformation(
            "Import created {Created} {TypeCode} document(s) spanning {Warehouses} warehouse(s) for user {UserId}: {Posted} posted, {Failed} refused",
            documents.Count, request.DocumentTypeCode, warehouseCount, userId, posted, failed.Count);

        return Result<ImportCreateResult>.Success(new ImportCreateResult
        {
            Documents = documents,
            Created = documents.Count,
            Posted = posted,
            Failed = failed,
        });
    }

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var found = await ReadAsync(id, permissions, DocumentAction.Delete, cancellationToken);
        if (found.IsFailure)
        {
            return found;
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

        _logger.LogInformation("Stock document {DocumentId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        // CREATE RATHER THAN VIEW. An attachment is evidence for the document — a delivery note, a
        // count sheet — so adding one is changing it, even on a posted document where nothing else can.
        var found = await ReadAsync(id, permissions, DocumentAction.Create, cancellationToken);
        if (found.IsFailure)
        {
            return Result<int>.Failure(found.ErrorType, found.Error ?? NotFoundMessage, found.Code ?? "NOT_FOUND");
        }

        try
        {
            var fileId = await _documents.AddFileAsync(id, fileName, contentType, content, fields, userId, cancellationToken);
            return Result<int>.Success(fileId);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result<int>.Failure(failure.Type, failure.Message, failure.Code);
        }
    }

    public async Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int id, int? attachmentTypeId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var found = await ReadAsync(id, permissions, DocumentAction.View, cancellationToken);
        if (found.IsFailure)
        {
            return Result<IReadOnlyList<DocumentFileDto>>.Failure(
                found.ErrorType, found.Error ?? NotFoundMessage, found.Code ?? "NOT_FOUND");
        }

        return Result<IReadOnlyList<DocumentFileDto>>.Success(
            await _documents.ListFilesAsync(id, attachmentTypeId, cancellationToken: cancellationToken));
    }

    public async Task<Result<DocumentFileDto>> UpdateFileAsync(
        int id, int fileId, DocumentFileEdit edit, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        // CREATE, as for the upload: the name, type and content of a file are part of the evidence.
        var found = await ReadAsync(id, permissions, DocumentAction.Create, cancellationToken);
        if (found.IsFailure)
        {
            return Result<DocumentFileDto>.Failure(found.ErrorType, found.Error ?? NotFoundMessage, found.Code ?? "NOT_FOUND");
        }

        if ((await _documents.ListFilesAsync(id, fileId: fileId, cancellationToken: cancellationToken)).Count == 0)
        {
            return Result<DocumentFileDto>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            var file = await _documents.UpdateFileAsync(fileId, edit, userId, cancellationToken);
            return file is null
                ? Result<DocumentFileDto>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
                : Result<DocumentFileDto>.Success(file);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result<DocumentFileDto>.Failure(failure.Type, failure.Message, failure.Code);
        }
    }

    public async Task<Result<StockDocumentFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var found = await ReadAsync(id, permissions, DocumentAction.View, cancellationToken);
        if (found.IsFailure)
        {
            return Result<StockDocumentFileContent>.Failure(
                found.ErrorType, found.Error ?? NotFoundMessage, found.Code ?? "NOT_FOUND");
        }

        var file = await _documents.GetFileAsync(fileId, cancellationToken);

        // CHECKED AGAINST THE DOCUMENT IN THE ROUTE, not taken on trust. File ids are sequential
        // across every document, so without this any reader of one document could fetch the
        // attachments of every other by counting.
        return file is null || file.DocumentId != id
            ? Result<StockDocumentFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<StockDocumentFileContent>.Success(file);
    }

    public async Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var found = await ReadAsync(id, permissions, DocumentAction.Create, cancellationToken);
        if (found.IsFailure)
        {
            return found;
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
        var found = await ReadAsync(id, permissions, DocumentAction.View, cancellationToken);
        if (found.IsFailure)
        {
            return Result<(byte[], string)>.Failure(
                found.ErrorType, found.Error ?? NotFoundMessage, found.Code ?? "NOT_FOUND");
        }

        var document = found.Value!;
        var name = string.IsNullOrWhiteSpace(document.DocumentNumber)
            ? $"{document.DocumentTypeCode}-draft-{document.Id}"
            : document.DocumentNumber;

        return Result<(byte[], string)>.Success((BuildWorkbook(document), $"{name}.xlsx"));
    }

    /// <summary>
    /// The document as somebody would file it: what it is at the top, the lines in the middle, the
    /// totals at the bottom.
    ///
    /// IT IS THE DOCUMENT, NOT A DATA DUMP. The header block is the reason a printed copy is worth
    /// anything — a list of item codes with no branch, date or reference on it cannot be checked
    /// against anything.
    /// </summary>
    private static byte[] BuildWorkbook(StockDocumentDto document)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(document.DocumentTypeName);

        sheet.Cell(1, 1).Value = document.DocumentTypeName;
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var header = new (string Label, string Value)[]
        {
            ("Document No.", document.DocumentNumber ?? "DRAFT"),
            ("Date", document.DocumentDate.ToString("dd/MM/yyyy")),
            ("Status", document.Status),
            ("Branch", $"{document.BranchCode} - {document.BranchName}"),
            ("Warehouse", $"{document.WarehouseCode} - {document.WarehouseName}"),
            ("Reason", document.ReasonName ?? string.Empty),
            ("Reference", document.ReferenceNo ?? string.Empty),
            ("Currency", document.CurrencyCode),
            ("Notes", document.Notes ?? string.Empty),
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
        // "Total Cost" rather than "Amount", so the download and the Document Details grid it came
        // from call the same figure the same thing.
        string[] columns = ["#", "Item Code", "Item Name", "Unit", "Warehouse", "Qty", "Unit Cost", "Total Cost", "Notes"];
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
            sheet.Cell(row, 4).Value = line.PackingFormula > 1
                ? $"{line.UnitTypeName} (x{line.PackingFormula})"
                : line.UnitTypeName;
            sheet.Cell(row, 5).Value = line.WarehouseCode;
            sheet.Cell(row, 6).Value = line.Quantity;
            sheet.Cell(row, 7).Value = line.UnitCost;
            sheet.Cell(row, 8).Value = line.LineTotal;
            sheet.Cell(row, 9).Value = line.Notes ?? string.Empty;
        }

        if (document.Lines.Count > 0)
        {
            sheet.Range(firstLineRow, 7, row, 8).Style.NumberFormat.Format = "#,##0.00";
        }

        // Shifted one column left with the table, so the totals keep their place against its right edge.
        row += 2;
        sheet.Cell(row, 5).Value = "Total Items";
        sheet.Cell(row, 6).Value = document.TotalItems;
        sheet.Cell(row + 1, 5).Value = "Total Quantity";
        sheet.Cell(row + 1, 6).Value = document.TotalQuantity;
        sheet.Cell(row + 2, 5).Value = $"Total Cost ({document.CurrencyCode})";
        sheet.Cell(row + 2, 6).Value = document.TotalCost;
        sheet.Cell(row + 2, 6).Style.NumberFormat.Format = "#,##0.00";
        sheet.Range(row, 5, row + 2, 5).Style.Font.Bold = true;

        sheet.Columns().AdjustToContents();
        sheet.Column(3).Width = 40;
        sheet.Column(10).Width = 30;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Reads a document and checks that this caller may do <paramref name="action"/> to a document of
    /// ITS type. Every entry point goes through here, so "which permission" is answered once.
    /// </summary>
    private async Task<Result<StockDocumentDto>> ReadAsync(
        int id, IReadOnlySet<string> permissions, DocumentAction action, CancellationToken cancellationToken)
    {
        var document = await _documents.GetAsync(id, cancellationToken);
        if (document is null)
        {
            return Failure(NotFoundMessage, ErrorType.NotFound, "NOT_FOUND");
        }

        return Allows(permissions, document.DocumentTypeCode, action)
            ? Result<StockDocumentDto>.Success(document)
            : Failure(ForbiddenMessage, ErrorType.Forbidden, "FORBIDDEN");
    }

    /// <summary>Post and Cancel differ only in which procedure runs and what the log line says.</summary>
    private async Task<Result<StockDocumentDto>> ChangeAsync(
        int id, IReadOnlySet<string> permissions, DocumentAction action, CancellationToken cancellationToken,
        Func<int, byte[]?, Task> change, string? rowVersion, int userId, string verb)
    {
        var found = await ReadAsync(id, permissions, action, cancellationToken);
        if (found.IsFailure)
        {
            return found;
        }

        try
        {
            await change(id, ToRowVersion(rowVersion));
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Stock document {DocumentId} {Verb} by user {UserId}", id, verb, userId);

        // Re-read: posting assigns the number, writes the ledger and moves the status, and the client
        // needs all three. The document is the server's answer, not a patch of what was sent.
        return await ReadAsync(id, permissions, DocumentAction.View, cancellationToken);
    }

    /// <summary>
    /// Which permission code answers "may this caller do this to this kind of document".
    ///
    /// A DOCUMENT'S TYPE PICKS THE FAMILY, the action picks the verb. Anything that is not one of the
    /// two inventory types is refused rather than defaulted: this service is the two of them, and a
    /// Purchase document reaching it would be a routing mistake, not a permission question.
    /// </summary>
    private static bool Allows(IReadOnlySet<string> permissions, string documentTypeCode, DocumentAction action)
    {
        var isIn = string.Equals(documentTypeCode, StockDocumentTypes.In, StringComparison.OrdinalIgnoreCase);
        var isOut = string.Equals(documentTypeCode, StockDocumentTypes.Out, StringComparison.OrdinalIgnoreCase);

        if (!isIn && !isOut)
        {
            return false;
        }

        var code = action switch
        {
            DocumentAction.Create => isIn ? Permissions.Inventory.StockInCreate : Permissions.Inventory.StockOutCreate,
            DocumentAction.Post => isIn ? Permissions.Inventory.StockInPost : Permissions.Inventory.StockOutPost,
            DocumentAction.Cancel => isIn ? Permissions.Inventory.StockInCancel : Permissions.Inventory.StockOutCancel,
            DocumentAction.Delete => isIn ? Permissions.Inventory.StockInDelete : Permissions.Inventory.StockOutDelete,
            _ => isIn ? Permissions.Inventory.StockInView : Permissions.Inventory.StockOutView,
        };

        return permissions.Contains(code);
    }

    private static Result<StockDocumentDto> Failure(string message, ErrorType type, string code)
        => Result<StockDocumentDto>.Failure(type, message, code);

    private static Result<StockDocumentDto> Failure(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<StockDocumentDto>.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified.
    ///
    /// THE MESSAGE IS ALWAYS THE PROCEDURE'S. "Line 3: Quantity must be at least 1", "Insufficient
    /// stock for TVS-AP160 in WH-001: available 3, required 5" — those sentences name the row and the
    /// numbers, and no house apology written here could be worth more. Only the CODE is added, so the
    /// client can react without reading English.
    /// </summary>
    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.StockDocumentValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.StockDocumentConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.StockDocumentNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.StockDocumentNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.StockDocumentInsufficientStock => new RuleFailure(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
        SqlErrors.StockDocumentMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),
        SqlErrors.StockDocumentNoLines => new RuleFailure(ErrorType.Validation, exception.Message, "NO_LINES"),
        SqlErrors.StockDocumentInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.StockDocumentAttachmentType => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
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
