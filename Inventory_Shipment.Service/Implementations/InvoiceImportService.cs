using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Implementations;

public sealed class InvoiceImportService : IInvoiceImportService
{
    /// <summary>The one code the client switches on for "your file is not usable", whatever was wrong with it.</summary>
    private const string InvalidFileCode = "INVALID_FILE";

    /// <summary>Header trouble: the branch, warehouse or price list, not anything in the file.</summary>
    private const string MasterInactiveCode = "MASTER_INACTIVE";

    private readonly IInvoiceImportRepository _imports;
    private readonly InvoiceImportParser _parser;
    private readonly InvoiceImportWorkbooks _workbooks;
    private readonly SalesOptions _options;
    private readonly ILogger<InvoiceImportService> _logger;

    public InvoiceImportService(
        IInvoiceImportRepository imports,
        InvoiceImportParser parser,
        InvoiceImportWorkbooks workbooks,
        IOptions<SalesOptions> options,
        ILogger<InvoiceImportService> logger)
    {
        _imports = imports;
        _parser = parser;
        _workbooks = workbooks;
        _options = options.Value;
        _logger = logger;
    }

    public byte[] GenerateTemplate() => _workbooks.GenerateTemplate();

    public byte[] GenerateErrorReport(IReadOnlyList<InvoiceImportValidatedRow> rows)
        => _workbooks.GenerateErrorReport(rows);

    public async Task<Result<ImportValidationResult>> ValidateAsync(
        Stream file,
        string fileName,
        long fileLength,
        int branchId,
        int warehouseId,
        int? priceListId,
        IReadOnlySet<string> userPermissions,
        CancellationToken cancellationToken = default)
    {
        if (fileLength <= 0)
        {
            return Invalid("The file is empty.");
        }

        if (fileLength > InvoiceImportParser.MaxFileBytes)
        {
            return Invalid($"The file is larger than {InvoiceImportParser.MaxFileBytes / (1024 * 1024)} MB.");
        }

        if (!fileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
        {
            return Invalid("Only .xlsx files can be imported. Save the file as an Excel workbook and try again.");
        }

        IReadOnlyList<InvoiceImportRow> rows;
        try
        {
            rows = _parser.Parse(file);
        }
        catch (InvoiceImportFileException ex)
        {
            // The parser's own sentence, unchanged: it is written for the person holding the file.
            return Invalid(ex.Message);
        }

        if (rows.Count == 0)
        {
            return Invalid("The file has no rows to import.");
        }

        // THE PERMISSION DECIDES, NOT THE REQUEST. A manual price in the file is only honoured for a
        // caller holding sales.invoices.priceoverride; everybody else gets the system price and a
        // warning saying so, which the procedure writes.
        var allowPriceOverride = userPermissions.Contains(Permissions.Sales.InvoicesPriceOverride);

        IReadOnlyList<InvoiceImportValidatedRow> validated;
        try
        {
            validated = await _imports.ValidateAsync(
                branchId, warehouseId, priceListId, allowPriceOverride,
                _options.MaxDiscountPercent, rows, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var code = ex.Number == SqlErrors.InvoiceImportMasterInactive ? MasterInactiveCode : InvalidFileCode;
            return Result<ImportValidationResult>.Failure(ErrorType.Validation, ex.Message, code);
        }

        var consolidated = Consolidate(validated);

        _logger.LogInformation(
            "Invoice import validated {FileName}: {Total} rows, {Valid} valid, {Warning} warning, {Error} error.",
            fileName, consolidated.Count,
            consolidated.Count(r => r.Status == InvoiceImportStatus.Valid),
            consolidated.Count(r => r.Status == InvoiceImportStatus.Warning),
            consolidated.Count(r => r.Status == InvoiceImportStatus.Error));

        return Result<ImportValidationResult>.Success(new ImportValidationResult
        {
            FileName = fileName,
            TotalRows = consolidated.Count,
            ValidRows = consolidated.Count(r => r.Status == InvoiceImportStatus.Valid),
            WarningRows = consolidated.Count(r => r.Status == InvoiceImportStatus.Warning),
            ErrorRows = consolidated.Count(r => r.Status == InvoiceImportStatus.Error),
            Rows = consolidated,
        });
    }

    public async Task<Result<int>> LogAsync(
        InvoiceImportLogRequest request, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            var id = await _imports.LogAsync(request, userId, cancellationToken);
            return Result<int>.Success(id);
        }
        catch (BusinessRuleException ex)
        {
            var code = ex.Number == SqlErrors.InvoiceImportMasterInactive ? MasterInactiveCode : "VALIDATION";
            return Result<int>.Failure(ErrorType.Validation, ex.Message, code);
        }
    }

    /// <summary>
    /// Merges rows that would produce the same invoice line (spec rule 16).
    ///
    /// WHY IT IS HERE AND NOT IN SQL. The procedure judges each row against master data; this is
    /// about the file as a whole, and it can only run once every row has been RESOLVED — two rows
    /// saying "OIL-001" and its barcode are the same line, and nothing before validation knows that.
    ///
    /// THE KEY IS EVERYTHING THAT MAKES A LINE DIFFERENT: item unit, warehouse, price, discount,
    /// expiry AND notes. Notes are in it deliberately — two rows with different notes are two things
    /// somebody wanted said, and silently keeping one of the two sentences is a worse outcome than a
    /// second line on the invoice.
    ///
    /// ONLY VALID AND WARNING ROWS ARE MERGED. An error row is not going to be imported, so folding
    /// it into another would hide it; and its resolved values are half-null anyway, which would make
    /// several unrelated broken rows look identical to each other.
    ///
    /// THE ABSORBED ROWS COME BACK as Merged rather than disappearing: somebody who wrote twelve rows
    /// and sees eight has to be able to find out what happened to the other four.
    /// </summary>
    private static List<InvoiceImportValidatedRow> Consolidate(IReadOnlyList<InvoiceImportValidatedRow> rows)
    {
        var targets = new Dictionary<string, InvoiceImportValidatedRow>(StringComparer.Ordinal);
        var absorbed = new Dictionary<int, List<int>>();

        foreach (var row in rows)
        {
            if (row.Status is not (InvoiceImportStatus.Valid or InvoiceImportStatus.Warning))
            {
                continue;
            }

            var key = string.Join('|',
                row.ItemUnitId,
                row.WarehouseId,
                row.UnitPrice,
                row.DiscountPercent,
                row.ExpiryDate?.ToString("yyyy-MM-dd"),
                row.Notes);

            if (!targets.TryGetValue(key, out var target))
            {
                targets.Add(key, row);
                continue;
            }

            target.Quantity = (target.Quantity ?? 0) + (row.Quantity ?? 0);
            row.Status = InvoiceImportStatus.Merged;
            row.Message = $"Merged into row {target.RowNumber}.";

            if (!absorbed.TryGetValue(target.RowNumber, out var list))
            {
                list = [];
                absorbed.Add(target.RowNumber, list);
            }

            list.Add(row.RowNumber);
        }

        foreach (var target in targets.Values)
        {
            if (!absorbed.TryGetValue(target.RowNumber, out var merged))
            {
                continue;
            }

            // A merged target becomes a WARNING even if it was Valid: its quantity is no longer the
            // number in its own row, and that is something the person has to be told rather than
            // discover on the invoice.
            var note = $"Merged with row(s) {string.Join(", ", merged)}";
            target.Status = InvoiceImportStatus.Warning;
            target.Message = string.IsNullOrWhiteSpace(target.Message)
                ? note + "."
                : $"{target.Message.TrimEnd()} {note}.";
        }

        // The file's own order, so the preview reads down the spreadsheet.
        return rows.OrderBy(r => r.RowNumber).ToList();
    }

    private static Result<ImportValidationResult> Invalid(string message)
        => Result<ImportValidationResult>.Failure(ErrorType.Validation, message, InvalidFileCode);
}
